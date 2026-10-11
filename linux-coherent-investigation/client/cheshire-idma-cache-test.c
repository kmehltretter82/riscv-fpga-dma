// SPDX-License-Identifier: GPL-2.0-only
/* Focused coherent positive and injected stale-data controls for Phase 11. */

#include <linux/cache.h>
#include <linux/completion.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <asm/dma-noncoherent.h>

#define TEST_LEN              256
#define STALE_SOURCE_LEN      16
#define DROPPED_DST_LINE      8
#define CACHE_LINE_BYTES      16
#define TEST_TIMEOUT_MS       1000
#define ARENA_BYTES           (3 * PAGE_SIZE)
#define SRC_OFFSET            64
/* 0x800 flips a legacy-CVA6 D-cache set bit (line bits are [11:4]). */
#define DST_REGION_OFFSET     0x800
#define DST_OFFSET            (DST_REGION_OFFSET + 64)
#define MAP_SPAN              (TEST_LEN + 128)

#define OLD_SRC               0x31
#define NEW_SRC               0xa7
#define OLD_DST               0x5c
#define PRE_GUARD             0xd3
#define POST_GUARD            0x6e

enum phase11_outcome {
	OUTCOME_NONE = 0,
	OUTCOME_NEW_SRC = 1,
	OUTCOME_OLD_SRC = 2,
	OUTCOME_OLD_DST = 3,
};

extern int cheshire_idma_test_prearm_source(struct dma_chan *chan,
					     dma_addr_t source);

struct phase11_buffers {
	u8 *allocation;
	u8 *base;
	u8 *src_region;
	u8 *dst_region;
	u8 *src;
	u8 *dst;
	dma_addr_t src_dma;
	dma_addr_t dst_dma;
	bool src_mapped;
	bool dst_mapped;
};

struct phase11_transfer {
	struct completion done;
	enum dmaengine_tx_result result;
	u32 residue;
	unsigned int callbacks;
};

static unsigned long pass;
static long test_rc;
static unsigned long jobs;
static unsigned long callbacks;
static unsigned long timeouts;
static unsigned long guard_failures;
static unsigned long payload_failures;
static unsigned long cache_total_delta;
static unsigned long positive_cache_delta;
static unsigned long positive_critical_delta;
static unsigned long stale_source_cache_delta;
static unsigned long stale_source_critical_delta;
static unsigned long stale_destination_cache_delta;
static unsigned long stale_destination_critical_delta;
static unsigned long positive_outcome;
static unsigned long stale_source_outcome;
static unsigned long stale_destination_outcome;

module_param(pass, ulong, 0444);
module_param(test_rc, long, 0444);
module_param(jobs, ulong, 0444);
module_param(callbacks, ulong, 0444);
module_param(timeouts, ulong, 0444);
module_param(guard_failures, ulong, 0444);
module_param(payload_failures, ulong, 0444);
module_param(cache_total_delta, ulong, 0444);
module_param(positive_cache_delta, ulong, 0444);
module_param(positive_critical_delta, ulong, 0444);
module_param(stale_source_cache_delta, ulong, 0444);
module_param(stale_source_critical_delta, ulong, 0444);
module_param(stale_destination_cache_delta, ulong, 0444);
module_param(stale_destination_critical_delta, ulong, 0444);
module_param(positive_outcome, ulong, 0444);
module_param(stale_source_outcome, ulong, 0444);
module_param(stale_destination_outcome, ulong, 0444);

static bool bytes_are(const u8 *buffer, size_t length, u8 value)
{
	size_t i;

	for (i = 0; i < length; i++)
		if (READ_ONCE(buffer[i]) != value)
			return false;
	return true;
}

static void fill_bytes(u8 *buffer, size_t length, u8 value)
{
	size_t i;

	for (i = 0; i < length; i++)
		WRITE_ONCE(buffer[i], value);
}

static bool stale_destination_matches(const u8 *buffer)
{
	size_t i;

	for (i = 0; i < TEST_LEN; i++) {
		u8 expected = i / CACHE_LINE_BYTES == DROPPED_DST_LINE ?
			      OLD_DST : NEW_SRC;

		if (READ_ONCE(buffer[i]) != expected)
			return false;
	}
	return true;
}

/* Force all sixteen hardware cache lines into L1 without changing memory. */
static u8 prime_lines(const u8 *buffer)
{
	u8 value = 0;
	size_t i;

	for (i = 0; i < TEST_LEN; i += 16)
		value ^= READ_ONCE(buffer[i]);
	barrier();
	return value;
}

static int buffers_alloc(struct phase11_buffers *buffers, u8 source)
{
	memset(buffers, 0, sizeof(*buffers));
	buffers->allocation = kmalloc(ARENA_BYTES + PAGE_SIZE - 1, GFP_KERNEL);
	if (!buffers->allocation)
		return -ENOMEM;
	buffers->base = PTR_ALIGN(buffers->allocation, PAGE_SIZE);
	buffers->src_region = buffers->base;
	buffers->dst_region = buffers->base + DST_REGION_OFFSET;
	buffers->src = buffers->base + SRC_OFFSET;
	buffers->dst = buffers->base + DST_OFFSET;

	fill_bytes(buffers->src_region, 64, PRE_GUARD);
	fill_bytes(buffers->src, TEST_LEN, source);
	fill_bytes(buffers->src + TEST_LEN, 64, POST_GUARD);
	fill_bytes(buffers->dst_region, 64, PRE_GUARD);
	fill_bytes(buffers->dst, TEST_LEN, OLD_DST);
	fill_bytes(buffers->dst + TEST_LEN, 64, POST_GUARD);
	return 0;
}

static int map_source(struct device *dev, struct phase11_buffers *buffers)
{
	buffers->src_dma = dma_map_single(dev, buffers->src_region, MAP_SPAN,
					  DMA_TO_DEVICE);
	if (dma_mapping_error(dev, buffers->src_dma))
		return -EIO;
	buffers->src_mapped = true;
	return 0;
}

static int map_destination(struct device *dev,
			   struct phase11_buffers *buffers)
{
	buffers->dst_dma = dma_map_single(dev, buffers->dst_region, MAP_SPAN,
					  DMA_FROM_DEVICE);
	if (dma_mapping_error(dev, buffers->dst_dma))
		return -EIO;
	buffers->dst_mapped = true;
	return 0;
}

static void unmap_source(struct device *dev, struct phase11_buffers *buffers)
{
	if (!buffers->src_mapped)
		return;
	dma_unmap_single(dev, buffers->src_dma, MAP_SPAN, DMA_TO_DEVICE);
	buffers->src_mapped = false;
}

static void unmap_destination(struct device *dev,
			      struct phase11_buffers *buffers)
{
	if (!buffers->dst_mapped)
		return;
	dma_unmap_single(dev, buffers->dst_dma, MAP_SPAN, DMA_FROM_DEVICE);
	buffers->dst_mapped = false;
}

static bool guards_ok(const struct phase11_buffers *buffers)
{
	return bytes_are(buffers->src_region, 64, PRE_GUARD) &&
	       bytes_are(buffers->src + TEST_LEN, 64, POST_GUARD) &&
	       bytes_are(buffers->dst_region, 64, PRE_GUARD) &&
	       bytes_are(buffers->dst + TEST_LEN, 64, POST_GUARD);
}

static void buffers_free(struct device *dev, struct phase11_buffers *buffers)
{
	unmap_destination(dev, buffers);
	unmap_source(dev, buffers);
	kfree(buffers->allocation);
	memset(buffers, 0, sizeof(*buffers));
}

static void transfer_callback(void *parameter,
			      const struct dmaengine_result *result)
{
	struct phase11_transfer *transfer = parameter;

	transfer->result = result->result;
	transfer->residue = result->residue;
	transfer->callbacks++;
	callbacks++;
	complete(&transfer->done);
}

static int transfer(struct dma_chan *channel, dma_addr_t destination,
		    dma_addr_t source, size_t length)
{
	struct dma_async_tx_descriptor *descriptor;
	struct phase11_transfer transfer;
	dma_cookie_t cookie;

	memset(&transfer, 0, sizeof(transfer));
	init_completion(&transfer.done);
	transfer.result = DMA_TRANS_ABORTED;
	transfer.residue = ~0U;
	descriptor = dmaengine_prep_dma_memcpy(channel, destination, source,
					       length,
					       DMA_PREP_INTERRUPT |
					       DMA_CTRL_ACK);
	if (!descriptor)
		return -EIO;
	descriptor->callback_result = transfer_callback;
	descriptor->callback_param = &transfer;
	cookie = dmaengine_submit(descriptor);
	if (dma_submit_error(cookie))
		return dma_submit_error(cookie);
	jobs++;
	dma_async_issue_pending(channel);
	if (!wait_for_completion_timeout(&transfer.done,
					 msecs_to_jiffies(TEST_TIMEOUT_MS))) {
		timeouts++;
		dmaengine_terminate_sync(channel);
		return -ETIMEDOUT;
	}
	dmaengine_synchronize(channel);
	if (transfer.callbacks != 1 || transfer.result != DMA_TRANS_NOERROR ||
	    transfer.residue)
		return -EIO;
	return 0;
}

static int finish_guards(struct phase11_buffers *buffers)
{
	if (guards_ok(buffers))
		return 0;
	guard_failures++;
	return -EIO;
}

static int run_positive(struct dma_chan *channel)
{
	struct device *dev = dmaengine_get_dma_device(channel);
	struct phase11_buffers buffers;
	unsigned long before, critical_before, critical_after;
	int ret;

	before = riscv_cheshire_cache_ops_count();
	ret = buffers_alloc(&buffers, NEW_SRC);
	if (ret)
		return ret;
	ret = map_source(dev, &buffers);
	if (ret)
		goto out;
	ret = map_destination(dev, &buffers);
	if (ret)
		goto out;
	/* Test-only ownership violation: make the post-DMA invalidate visible. */
	if (prime_lines(buffers.dst) != ((TEST_LEN / 16) & 1 ? OLD_DST : 0)) {
		ret = -EIO;
		goto out;
	}
	critical_before = riscv_cheshire_cache_ops_count();
	ret = transfer(channel, buffers.dst_dma + SRC_OFFSET,
		       buffers.src_dma + SRC_OFFSET, TEST_LEN);
	critical_after = riscv_cheshire_cache_ops_count();
	positive_critical_delta = critical_after - critical_before;
	if (ret)
		goto out;
	unmap_destination(dev, &buffers);
	unmap_source(dev, &buffers);
	positive_cache_delta = riscv_cheshire_cache_ops_count() - before;
	if (bytes_are(buffers.dst, TEST_LEN, NEW_SRC))
		positive_outcome = OUTCOME_NEW_SRC;
	else
		payload_failures++;
	if (positive_outcome != OUTCOME_NEW_SRC || positive_cache_delta != 0 ||
	    positive_critical_delta) {
		ret = -EIO;
		goto out;
	}
	ret = finish_guards(&buffers);
out:
	buffers_free(dev, &buffers);
	return ret;
}

static int run_stale_source(struct dma_chan *channel)
{
	struct device *dev = dmaengine_get_dma_device(channel);
	struct phase11_buffers buffers;
	unsigned long before, critical_before, critical_after;
	dma_addr_t stale_source_dma;
	int ret;

	before = riscv_cheshire_cache_ops_count();
	ret = buffers_alloc(&buffers, OLD_SRC);
	if (ret)
		return ret;
	/* Commit OLD_SRC to RAM and retain its direct DMA address. */
	ret = map_source(dev, &buffers);
	if (ret)
		goto out;
	stale_source_dma = buffers.src_dma;
	unmap_source(dev, &buffers);
	/* Complete every unrelated cache operation before dirtying NEW_SRC. */
	ret = map_destination(dev, &buffers);
	if (ret)
		goto out;
	/* Establish OLD_SRC in RAM before the deliberate WT-buffer hold begins. */
	mb();
	ret = cheshire_idma_test_prearm_source(channel,
					       stale_source_dma + SRC_OFFSET);
	if (ret)
		goto out;
	/* One aligned WT line fits in one coalescing write-buffer entry. */
	fill_bytes(buffers.src, STALE_SOURCE_LEN, NEW_SRC);
	critical_before = riscv_cheshire_cache_ops_count();
	ret = transfer(channel, buffers.dst_dma + SRC_OFFSET,
		       stale_source_dma + SRC_OFFSET, STALE_SOURCE_LEN);
	critical_after = riscv_cheshire_cache_ops_count();
	stale_source_critical_delta = critical_after - critical_before;
	if (ret)
		goto out;
	unmap_destination(dev, &buffers);
	stale_source_cache_delta = riscv_cheshire_cache_ops_count() - before;
	if (bytes_are(buffers.dst, STALE_SOURCE_LEN, OLD_SRC))
		stale_source_outcome = OUTCOME_OLD_SRC;
	else
		payload_failures++;
	if (!bytes_are(buffers.src, STALE_SOURCE_LEN, NEW_SRC))
		payload_failures++;
	if (stale_source_outcome != OUTCOME_OLD_SRC ||
	    stale_source_cache_delta != 0 || stale_source_critical_delta) {
		ret = -EIO;
		goto out;
	}
	ret = finish_guards(&buffers);
out:
	buffers_free(dev, &buffers);
	return ret;
}

static int run_stale_destination(struct dma_chan *channel)
{
	struct device *dev = dmaengine_get_dma_device(channel);
	struct phase11_buffers buffers;
	unsigned long before, critical_before, critical_after;
	int ret;

	before = riscv_cheshire_cache_ops_count();
	ret = buffers_alloc(&buffers, NEW_SRC);
	if (ret)
		return ret;
	ret = map_source(dev, &buffers);
	if (ret)
		goto out;
	ret = map_destination(dev, &buffers);
	if (ret)
		goto out;
	/* Refill OLD_DST after pre-DMA invalidation, then omit CPU sync. */
	if (prime_lines(buffers.dst) != ((TEST_LEN / 16) & 1 ? OLD_DST : 0)) {
		ret = -EIO;
		goto out;
	}
	critical_before = riscv_cheshire_cache_ops_count();
	ret = transfer(channel, buffers.dst_dma + SRC_OFFSET,
		       buffers.src_dma + SRC_OFFSET, TEST_LEN);
	if (ret)
		goto out;
	/*
	 * This read deliberately precedes dma_unmap_single(FROM_DEVICE).
	 * Hardware drops only line 8's invalidation: that line must retain
	 * OLD_DST, while all fifteen invalidated lines must expose NEW_SRC.
	 */
	if (stale_destination_matches(buffers.dst))
		stale_destination_outcome = OUTCOME_OLD_DST;
	else
		payload_failures++;
	critical_after = riscv_cheshire_cache_ops_count();
	stale_destination_critical_delta = critical_after - critical_before;
	unmap_destination(dev, &buffers);
	unmap_source(dev, &buffers);
	stale_destination_cache_delta =
		riscv_cheshire_cache_ops_count() - before;
	if (stale_destination_outcome != OUTCOME_OLD_DST ||
	    stale_destination_cache_delta != 0 ||
	    stale_destination_critical_delta) {
		ret = -EIO;
		goto out;
	}
	ret = finish_guards(&buffers);
out:
	buffers_free(dev, &buffers);
	return ret;
}

static int phase11_probe(struct platform_device *pdev)
{
	struct dma_chan *channel;
	unsigned long before;
	int ret;

	channel = dma_request_chan(&pdev->dev, "memcpy");
	if (IS_ERR(channel)) {
		test_rc = PTR_ERR(channel);
		return test_rc;
	}
	before = riscv_cheshire_cache_ops_count();
	ret = run_positive(channel);
	if (!ret)
		ret = run_stale_source(channel);
	if (!ret)
		ret = run_stale_destination(channel);
	cache_total_delta = riscv_cheshire_cache_ops_count() - before;
	dma_release_channel(channel);

	if (!ret && (jobs != 3 || callbacks != 3 || timeouts ||
		    guard_failures || payload_failures || cache_total_delta != 0))
		ret = -EIO;
	test_rc = ret;
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
			"Phase 11 cache oracle failed\n");
	pass = 1;
	dev_info(&pdev->dev,
		 "PHASE11-CACHE-CLIENT-PASS jobs=%lu callbacks=%lu cache=%lu\n",
		 jobs, callbacks, cache_total_delta);
	return 0;
}

static const struct of_device_id phase11_of_match[] = {
	{ .compatible = "openai,cheshire-idma-cache-test" },
	{ }
};
MODULE_DEVICE_TABLE(of, phase11_of_match);

static struct platform_driver phase11_driver = {
	.probe = phase11_probe,
	.driver = {
		.name = "cheshire-idma-cache-test",
		.of_match_table = phase11_of_match,
	},
};
module_platform_driver(phase11_driver);

MODULE_DESCRIPTION("Phase 11 CVA6-WT/iDMA hardware-coherence oracle");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
