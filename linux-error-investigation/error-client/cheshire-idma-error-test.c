// SPDX-License-Identifier: GPL-2.0-only
/* Bounded Linux DMAengine client for Cheshire AXI error propagation. */

#include <linux/cache.h>
#include <linux/completion.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/ioport.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <asm/dma-noncoherent.h>

#define TEST_LEN        8
#define TEST_TIMEOUT_MS 1000
#define PRE_GUARD       0xa5
#define POST_GUARD      0x5a
#define DST_FILL        0xcc

enum test_kind {
	TEST_CLEAN,
	TEST_READ_ERROR,
	TEST_WRITE_ERROR,
};

struct test_case {
	const char *name;
	enum test_kind kind;
	enum dmaengine_tx_result expected;
	resource_size_t fault_addr;
};

struct scratch {
	u8 *allocation;
	u8 *base;
	u8 *payload;
	dma_addr_t dma_base;
	enum dma_data_direction direction;
	bool mapped;
};

struct callback_state {
	struct completion done;
	enum dmaengine_tx_result result;
	u32 residue;
};

static unsigned long submitted;
static unsigned long completed;
static unsigned long success;
static unsigned long read_failed;
static unsigned long write_failed;
static unsigned long aborted;
static unsigned long callback_mismatch;
static unsigned long clean_checks;
static unsigned long guard_failures;
static unsigned long cache_ops_delta;

module_param(submitted, ulong, 0444);
module_param(completed, ulong, 0444);
module_param(success, ulong, 0444);
module_param(read_failed, ulong, 0444);
module_param(write_failed, ulong, 0444);
module_param(aborted, ulong, 0444);
module_param(callback_mismatch, ulong, 0444);
module_param(clean_checks, ulong, 0444);
module_param(guard_failures, ulong, 0444);
module_param(cache_ops_delta, ulong, 0444);

static void result_callback(void *param, const struct dmaengine_result *result)
{
	struct callback_state *state = param;

	state->result = result->result;
	state->residue = result->residue;
	completed++;
	switch (result->result) {
	case DMA_TRANS_NOERROR:
		success++;
		break;
	case DMA_TRANS_READ_FAILED:
		read_failed++;
		break;
	case DMA_TRANS_WRITE_FAILED:
		write_failed++;
		break;
	case DMA_TRANS_ABORTED:
		aborted++;
		break;
	}
	complete(&state->done);
}

static int scratch_alloc(struct scratch *scratch,
			 enum dma_data_direction direction, u8 payload_seed)
{
	size_t span = 3 * L1_CACHE_BYTES;
	size_t allocation = span + L1_CACHE_BYTES - 1;

	scratch->allocation = kmalloc(allocation, GFP_KERNEL);
	if (!scratch->allocation)
		return -ENOMEM;
	scratch->base = PTR_ALIGN(scratch->allocation, L1_CACHE_BYTES);
	scratch->payload = scratch->base + L1_CACHE_BYTES;
	scratch->direction = direction;
	memset(scratch->base, PRE_GUARD, L1_CACHE_BYTES);
	memset(scratch->payload, payload_seed, L1_CACHE_BYTES);
	memset(scratch->payload + L1_CACHE_BYTES, POST_GUARD,
	       L1_CACHE_BYTES);
	return 0;
}

static int scratch_map(struct device *dma_dev, struct scratch *scratch)
{
	size_t span = 3 * L1_CACHE_BYTES;

	scratch->dma_base = dma_map_single(dma_dev, scratch->base, span,
					   scratch->direction);
	if (dma_mapping_error(dma_dev, scratch->dma_base))
		return -EIO;
	scratch->mapped = true;
	return 0;
}

static void scratch_unmap(struct device *dma_dev, struct scratch *scratch)
{
	if (scratch->mapped) {
		dma_unmap_single(dma_dev, scratch->dma_base,
				 3 * L1_CACHE_BYTES, scratch->direction);
		scratch->mapped = false;
	}
}

static bool scratch_guards_ok(const struct scratch *scratch)
{
	size_t i;

	for (i = 0; i < L1_CACHE_BYTES; i++) {
		if (scratch->base[i] != PRE_GUARD ||
		    scratch->payload[L1_CACHE_BYTES + i] != POST_GUARD)
			return false;
	}
	return true;
}

static void scratch_free(struct scratch *scratch)
{
	kfree(scratch->allocation);
	scratch->allocation = NULL;
}

static int run_case(struct device *dev, struct dma_chan *chan,
		    const struct test_case *test, unsigned int index)
{
	struct device *dma_dev = dmaengine_get_dma_device(chan);
	struct dma_async_tx_descriptor *tx;
	struct callback_state callback = {
		.result = DMA_TRANS_ABORTED,
		.residue = ~0U,
	};
	struct scratch src = { };
	struct scratch dst = { };
	dma_addr_t src_dma = 0, dst_dma = 0;
	bool src_resource = false, dst_resource = false;
	dma_cookie_t cookie;
	unsigned long waited;
	int ret = 0;
	u8 source_seed = 0x20 + index;

	if (test->kind != TEST_READ_ERROR) {
		ret = scratch_alloc(&src, DMA_TO_DEVICE, source_seed);
		if (ret)
			goto out;
		ret = scratch_map(dma_dev, &src);
		if (ret)
			goto out;
		src_dma = src.dma_base + L1_CACHE_BYTES;
	} else {
		src_dma = dma_map_resource(dma_dev, test->fault_addr, TEST_LEN,
					   DMA_TO_DEVICE, 0);
		if (dma_mapping_error(dma_dev, src_dma)) {
			ret = -EIO;
			goto out;
		}
		src_resource = true;
	}

	if (test->kind != TEST_WRITE_ERROR) {
		ret = scratch_alloc(&dst, DMA_FROM_DEVICE, DST_FILL);
		if (ret)
			goto out;
		ret = scratch_map(dma_dev, &dst);
		if (ret)
			goto out;
		dst_dma = dst.dma_base + L1_CACHE_BYTES;
	} else {
		dst_dma = dma_map_resource(dma_dev, test->fault_addr, TEST_LEN,
					   DMA_FROM_DEVICE, 0);
		if (dma_mapping_error(dma_dev, dst_dma)) {
			ret = -EIO;
			goto out;
		}
		dst_resource = true;
	}

	init_completion(&callback.done);
	tx = dmaengine_prep_dma_memcpy(chan, dst_dma, src_dma, TEST_LEN,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!tx) {
		ret = -EIO;
		goto out;
	}
	tx->callback_result = result_callback;
	tx->callback_param = &callback;
	cookie = dmaengine_submit(tx);
	ret = dma_submit_error(cookie);
	if (ret)
		goto out;
	submitted++;
	dma_async_issue_pending(chan);
	waited = wait_for_completion_timeout(&callback.done,
					     msecs_to_jiffies(TEST_TIMEOUT_MS));
	if (!waited) {
		dev_err(dev, "job %s timed out\n", test->name);
		dmaengine_terminate_sync(chan);
		ret = -ETIMEDOUT;
		goto out;
	}
	dmaengine_synchronize(chan);

	if (callback.result != test->expected || callback.residue) {
		callback_mismatch++;
		dev_err(dev,
			"job %s result mismatch: got=%u residue=%u expected=%u\n",
			test->name, callback.result, callback.residue,
			test->expected);
		ret = -EIO;
	}

out:
	if (dst_resource)
		dma_unmap_resource(dma_dev, dst_dma, TEST_LEN,
				   DMA_FROM_DEVICE, 0);
	scratch_unmap(dma_dev, &dst);
	if (src_resource)
		dma_unmap_resource(dma_dev, src_dma, TEST_LEN,
				   DMA_TO_DEVICE, 0);
	scratch_unmap(dma_dev, &src);

	if (src.allocation && !scratch_guards_ok(&src)) {
		guard_failures++;
		ret = -EIO;
	}
	if (dst.allocation && !scratch_guards_ok(&dst)) {
		guard_failures++;
		ret = -EIO;
	}
	if (!ret && test->kind == TEST_CLEAN) {
		if (memcmp(src.payload, dst.payload, TEST_LEN)) {
			dev_err(dev, "job %s payload mismatch\n", test->name);
			ret = -EIO;
		} else {
			clean_checks++;
		}
	}

	dev_info(dev, "job=%s result=%u expected=%u residue=%u rc=%d\n",
		 test->name, callback.result, test->expected, callback.residue, ret);
	scratch_free(&dst);
	scratch_free(&src);
	return ret;
}

static int cheshire_error_test_probe(struct platform_device *pdev)
{
	struct resource *slverr_res;
	struct resource *decerr_res;
	struct dma_chan *chan;
	unsigned long cache_before;
	unsigned int i;
	int ret;
	struct test_case tests[9];

	slverr_res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "slverr");
	decerr_res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "decerr");
	if (!slverr_res || !decerr_res)
		return -EINVAL;
	if (resource_size(slverr_res) < TEST_LEN ||
	    resource_size(decerr_res) < TEST_LEN)
		return -EINVAL;

	tests[0] = (struct test_case) { "clean-0", TEST_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	tests[1] = (struct test_case) { "read-slverr", TEST_READ_ERROR,
		DMA_TRANS_READ_FAILED, slverr_res->start };
	tests[2] = (struct test_case) { "clean-after-read-slverr", TEST_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	tests[3] = (struct test_case) { "write-slverr", TEST_WRITE_ERROR,
		DMA_TRANS_WRITE_FAILED, slverr_res->start };
	tests[4] = (struct test_case) { "clean-after-write-slverr", TEST_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	tests[5] = (struct test_case) { "read-decerr", TEST_READ_ERROR,
		DMA_TRANS_READ_FAILED, decerr_res->start };
	tests[6] = (struct test_case) { "clean-after-read-decerr", TEST_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	tests[7] = (struct test_case) { "write-decerr", TEST_WRITE_ERROR,
		DMA_TRANS_WRITE_FAILED, decerr_res->start };
	tests[8] = (struct test_case) { "clean-after-write-decerr", TEST_CLEAN,
		DMA_TRANS_NOERROR, 0 };

	chan = dma_request_chan(&pdev->dev, "memcpy");
	if (IS_ERR(chan))
		return dev_err_probe(&pdev->dev, PTR_ERR(chan),
				     "failed to request DMA channel\n");

	cache_before = riscv_cheshire_cache_ops_count();
	for (i = 0; i < ARRAY_SIZE(tests); i++) {
		ret = run_case(&pdev->dev, chan, &tests[i], i);
		if (ret)
			goto out_release;
	}
	cache_ops_delta = riscv_cheshire_cache_ops_count() - cache_before;

	if (submitted != 9 || completed != 9 || success != 5 ||
	    read_failed != 2 || write_failed != 2 || aborted ||
	    callback_mismatch || clean_checks != 5 || guard_failures ||
	    cache_ops_delta != 21) {
		dev_err(&pdev->dev,
			"matrix mismatch submitted=%lu completed=%lu success=%lu read_failed=%lu write_failed=%lu aborted=%lu callback_mismatch=%lu clean_checks=%lu guard_failures=%lu cache_delta=%lu\n",
			submitted, completed, success, read_failed, write_failed,
			aborted, callback_mismatch, clean_checks, guard_failures,
			cache_ops_delta);
		ret = -EIO;
		goto out_release;
	}

	dev_info(&pdev->dev,
		 "FPGA-LINUX-DMA-ERROR-CLIENT-PASS submitted=9 completed=9 success=5 read_failed=2 write_failed=2 cache_delta=21\n");
	ret = 0;

out_release:
	dma_release_channel(chan);
	return ret;
}

static const struct of_device_id cheshire_error_test_of_match[] = {
	{ .compatible = "openai,cheshire-idma-error-test" },
	{ }
};
MODULE_DEVICE_TABLE(of, cheshire_error_test_of_match);

static struct platform_driver cheshire_error_test_driver = {
	.probe = cheshire_error_test_probe,
	.driver = {
		.name = "cheshire-idma-error-test",
		.of_match_table = cheshire_error_test_of_match,
	},
};
module_platform_driver(cheshire_error_test_driver);

MODULE_DESCRIPTION("Bounded Cheshire DMAengine AXI error test client");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
