// SPDX-License-Identifier: GPL-2.0-only
/* Bounded DMAengine client for the Cheshire IRQ/queue/abort investigation. */

#include <linux/cache.h>
#include <linux/completion.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/ioport.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <asm/dma-noncoherent.h>

#define TEST_TIMEOUT_MS       1000
#define SERIAL_JOBS           8
#define QUEUE_JOBS            16
#define THREADS               2
#define JOBS_PER_THREAD       16
#define ERROR_JOBS            9
#define TERMINATE_JOBS        8
#define TERMINATE_LEN         131073
#define ERROR_LEN             8
#define EXPECTED_CACHE_OPS    216
#define PRE_GUARD             0xa5
#define POST_GUARD            0x5a
#define DST_FILL              0xcc

struct scratch {
	u8 *allocation;
	u8 *base;
	u8 *payload;
	size_t len;
	size_t span;
	dma_addr_t dma_base;
	enum dma_data_direction direction;
	bool mapped;
	bool source;
	u8 seed;
};

struct transfer_ctx {
	struct scratch src;
	struct scratch dst;
	struct completion done;
	enum dmaengine_tx_result result;
	u32 residue;
	dma_cookie_t cookie;
	unsigned int callback_order;
	unsigned int callback_count;
};

struct submit_thread {
	struct dma_chan *chan;
	struct transfer_ctx *ctx;
	struct completion *start;
	struct completion done;
	unsigned int id;
	unsigned int prepared;
	int ret;
};

enum error_kind {
	ERROR_CLEAN,
	ERROR_READ,
	ERROR_WRITE,
};

struct error_case {
	const char *name;
	enum error_kind kind;
	enum dmaengine_tx_result expected;
	resource_size_t addr;
};

static atomic_t callback_sequence = ATOMIC_INIT(0);
static atomic_t all_callbacks = ATOMIC_INIT(0);

static unsigned long pass;
static long test_rc;
static unsigned long serial_submitted;
static unsigned long serial_completed;
static unsigned long serial_checks;
static unsigned long queue_submitted;
static unsigned long queue_completed;
static unsigned long queue_checks;
static unsigned long queue_order_failures;
static unsigned long concurrent_submitted;
static unsigned long concurrent_completed;
static unsigned long concurrent_checks;
static unsigned long thread_failures;
static unsigned long error_submitted;
static unsigned long error_completed;
static unsigned long error_success;
static unsigned long error_read_failed;
static unsigned long error_write_failed;
static unsigned long error_aborted;
static unsigned long error_mismatch;
static unsigned long error_clean_checks;
static unsigned long terminate_submitted;
static unsigned long terminate_callbacks;
static unsigned long terminate_checks;
static unsigned long recovery_checks;
static unsigned long guard_failures;
static unsigned long payload_failures;
static unsigned long callback_duplicates;
static unsigned long timeouts;
static unsigned long cache_ops_delta;

module_param(pass, ulong, 0444);
module_param(test_rc, long, 0444);
module_param(serial_submitted, ulong, 0444);
module_param(serial_completed, ulong, 0444);
module_param(serial_checks, ulong, 0444);
module_param(queue_submitted, ulong, 0444);
module_param(queue_completed, ulong, 0444);
module_param(queue_checks, ulong, 0444);
module_param(queue_order_failures, ulong, 0444);
module_param(concurrent_submitted, ulong, 0444);
module_param(concurrent_completed, ulong, 0444);
module_param(concurrent_checks, ulong, 0444);
module_param(thread_failures, ulong, 0444);
module_param(error_submitted, ulong, 0444);
module_param(error_completed, ulong, 0444);
module_param(error_success, ulong, 0444);
module_param(error_read_failed, ulong, 0444);
module_param(error_write_failed, ulong, 0444);
module_param(error_aborted, ulong, 0444);
module_param(error_mismatch, ulong, 0444);
module_param(error_clean_checks, ulong, 0444);
module_param(terminate_submitted, ulong, 0444);
module_param(terminate_callbacks, ulong, 0444);
module_param(terminate_checks, ulong, 0444);
module_param(recovery_checks, ulong, 0444);
module_param(guard_failures, ulong, 0444);
module_param(payload_failures, ulong, 0444);
module_param(callback_duplicates, ulong, 0444);
module_param(timeouts, ulong, 0444);
module_param(cache_ops_delta, ulong, 0444);

static u8 payload_byte(u8 seed, size_t offset)
{
	return (u8)(seed + offset * 37u + (offset >> 3));
}

static int scratch_alloc(struct scratch *scratch, size_t len,
			 enum dma_data_direction direction, bool source, u8 seed)
{
	size_t allocation;
	size_t i;

	scratch->len = len;
	scratch->span = len + 2 * L1_CACHE_BYTES;
	allocation = scratch->span + L1_CACHE_BYTES - 1;
	scratch->allocation = kmalloc(allocation, GFP_KERNEL);
	if (!scratch->allocation)
		return -ENOMEM;
	scratch->base = PTR_ALIGN(scratch->allocation, L1_CACHE_BYTES);
	scratch->payload = scratch->base + L1_CACHE_BYTES;
	scratch->direction = direction;
	scratch->source = source;
	scratch->seed = seed;
	memset(scratch->base, PRE_GUARD, L1_CACHE_BYTES);
	if (source) {
		for (i = 0; i < len; i++)
			scratch->payload[i] = payload_byte(seed, i);
	} else {
		memset(scratch->payload, DST_FILL, len);
	}
	memset(scratch->payload + len, POST_GUARD, L1_CACHE_BYTES);
	return 0;
}

static int scratch_map(struct device *dev, struct scratch *scratch)
{
	scratch->dma_base = dma_map_single(dev, scratch->base, scratch->span,
					   scratch->direction);
	if (dma_mapping_error(dev, scratch->dma_base))
		return -EIO;
	scratch->mapped = true;
	return 0;
}

static void scratch_unmap(struct device *dev, struct scratch *scratch)
{
	if (!scratch->mapped)
		return;
	dma_unmap_single(dev, scratch->dma_base, scratch->span,
			 scratch->direction);
	scratch->mapped = false;
}

static bool scratch_guards_ok(const struct scratch *scratch)
{
	size_t i;

	for (i = 0; i < L1_CACHE_BYTES; i++) {
		if (scratch->base[i] != PRE_GUARD ||
		    scratch->payload[scratch->len + i] != POST_GUARD)
			return false;
	}
	return true;
}

static bool scratch_source_ok(const struct scratch *scratch)
{
	size_t i;

	for (i = 0; i < scratch->len; i++)
		if (scratch->payload[i] != payload_byte(scratch->seed, i))
			return false;
	return true;
}

static bool scratch_is_fill(const struct scratch *scratch)
{
	size_t i;

	for (i = 0; i < scratch->len; i++)
		if (scratch->payload[i] != DST_FILL)
			return false;
	return true;
}

static void scratch_free(struct scratch *scratch)
{
	kfree(scratch->allocation);
	memset(scratch, 0, sizeof(*scratch));
}

static void transfer_callback(void *param,
			      const struct dmaengine_result *result)
{
	struct transfer_ctx *ctx = param;

	ctx->result = result->result;
	ctx->residue = result->residue;
	ctx->callback_count++;
	ctx->callback_order = atomic_inc_return(&callback_sequence);
	atomic_inc(&all_callbacks);
	complete(&ctx->done);
}

static int prepare_clean(struct dma_chan *chan, struct transfer_ctx *ctx,
			 size_t len, u8 seed)
{
	struct device *dev = dmaengine_get_dma_device(chan);
	struct dma_async_tx_descriptor *tx;
	int ret;

	memset(ctx, 0, sizeof(*ctx));
	init_completion(&ctx->done);
	ctx->result = DMA_TRANS_ABORTED;
	ctx->residue = ~0U;
	ret = scratch_alloc(&ctx->src, len, DMA_TO_DEVICE, true, seed);
	if (ret)
		return ret;
	ret = scratch_alloc(&ctx->dst, len, DMA_FROM_DEVICE, false, 0);
	if (ret)
		return ret;
	ret = scratch_map(dev, &ctx->src);
	if (ret)
		return ret;
	ret = scratch_map(dev, &ctx->dst);
	if (ret)
		return ret;

	tx = dmaengine_prep_dma_memcpy(chan,
			ctx->dst.dma_base + L1_CACHE_BYTES,
			ctx->src.dma_base + L1_CACHE_BYTES, len,
			DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!tx)
		return -EIO;
	tx->callback_result = transfer_callback;
	tx->callback_param = ctx;
	ctx->cookie = dmaengine_submit(tx);
	return dma_submit_error(ctx->cookie);
}

static int wait_transfer(struct transfer_ctx *ctx)
{
	if (!wait_for_completion_timeout(&ctx->done,
					 msecs_to_jiffies(TEST_TIMEOUT_MS))) {
		timeouts++;
		return -ETIMEDOUT;
	}
	if (ctx->callback_count != 1) {
		callback_duplicates++;
		return -EIO;
	}
	return 0;
}

static int finish_clean(struct dma_chan *chan, struct transfer_ctx *ctx,
			bool expect_copy)
{
	struct device *dev = dmaengine_get_dma_device(chan);
	int ret = 0;

	scratch_unmap(dev, &ctx->dst);
	scratch_unmap(dev, &ctx->src);
	if (!scratch_guards_ok(&ctx->src) ||
	    !scratch_guards_ok(&ctx->dst)) {
		guard_failures++;
		ret = -EIO;
	}
	if (!scratch_source_ok(&ctx->src)) {
		payload_failures++;
		ret = -EIO;
	}
	if (expect_copy && memcmp(ctx->src.payload, ctx->dst.payload,
				  ctx->src.len)) {
		payload_failures++;
		ret = -EIO;
	}
	scratch_free(&ctx->dst);
	scratch_free(&ctx->src);
	return ret;
}

static void cleanup_context(struct dma_chan *chan, struct transfer_ctx *ctx)
{
	struct device *dev = dmaengine_get_dma_device(chan);

	scratch_unmap(dev, &ctx->dst);
	scratch_unmap(dev, &ctx->src);
	scratch_free(&ctx->dst);
	scratch_free(&ctx->src);
}

static int run_serial_group(struct dma_chan *chan)
{
	static const size_t sizes[SERIAL_JOBS] = {
		8, 64, 257, 4096, 4097, 8191, 8192, 12289,
	};
	unsigned int i;

	for (i = 0; i < SERIAL_JOBS; i++) {
		struct transfer_ctx ctx;
		int ret;

		ret = prepare_clean(chan, &ctx, sizes[i], 0x10 + i);
		if (ret) {
			cleanup_context(chan, &ctx);
			return ret;
		}
		serial_submitted++;
		dma_async_issue_pending(chan);
		ret = wait_transfer(&ctx);
		if (ret) {
			dmaengine_terminate_sync(chan);
			cleanup_context(chan, &ctx);
			return ret;
		}
		dmaengine_synchronize(chan);
		serial_completed++;
		if (ctx.result != DMA_TRANS_NOERROR || ctx.residue) {
			cleanup_context(chan, &ctx);
			return -EIO;
		}
		ret = finish_clean(chan, &ctx, true);
		if (ret)
			return ret;
		serial_checks++;
	}
	return 0;
}

static int run_queue_group(struct dma_chan *chan)
{
	struct transfer_ctx *ctx;
	unsigned int prepared = 0;
	unsigned int i;
	int order_base;
	int ret = 0;

	ctx = kcalloc(QUEUE_JOBS, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	order_base = atomic_read(&callback_sequence);
	for (i = 0; i < QUEUE_JOBS; i++) {
		ret = prepare_clean(chan, &ctx[i], 64 + i * 7, 0x30 + i);
		if (ret)
			goto terminate;
		prepared++;
		queue_submitted++;
	}
	dma_async_issue_pending(chan);
	for (i = 0; i < QUEUE_JOBS; i++) {
		ret = wait_transfer(&ctx[i]);
		if (ret)
			goto terminate;
	}
	dmaengine_synchronize(chan);
	for (i = 0; i < QUEUE_JOBS; i++) {
		queue_completed++;
		if (ctx[i].result != DMA_TRANS_NOERROR || ctx[i].residue ||
		    ctx[i].callback_order != order_base + i + 1) {
			queue_order_failures++;
			ret = -EIO;
		}
		if (finish_clean(chan, &ctx[i], true))
			ret = -EIO;
		else
			queue_checks++;
	}
	kfree(ctx);
	return ret;

terminate:
	dmaengine_terminate_sync(chan);
	for (i = 0; i < prepared; i++)
		cleanup_context(chan, &ctx[i]);
	kfree(ctx);
	return ret;
}

static int submit_thread_fn(void *data)
{
	struct submit_thread *thread = data;
	unsigned int i;

	wait_for_completion(thread->start);
	for (i = 0; i < JOBS_PER_THREAD; i++) {
		thread->ret = prepare_clean(thread->chan, &thread->ctx[i],
					    96 + i * 11,
					    0x60 + thread->id * 32 + i);
		if (thread->ret)
			break;
		thread->prepared++;
	}
	complete(&thread->done);
	return thread->ret;
}

static int run_concurrent_group(struct dma_chan *chan)
{
	struct transfer_ctx *ctx;
	struct submit_thread thread[THREADS];
	struct task_struct *task[THREADS] = { };
	struct completion start;
	unsigned int t, i;
	int ret = 0;

	ctx = kcalloc(THREADS * JOBS_PER_THREAD, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	memset(thread, 0, sizeof(thread));
	init_completion(&start);
	for (t = 0; t < THREADS; t++) {
		thread[t].chan = chan;
		thread[t].ctx = &ctx[t * JOBS_PER_THREAD];
		thread[t].start = &start;
		thread[t].id = t;
		init_completion(&thread[t].done);
		task[t] = kthread_run(submit_thread_fn, &thread[t],
				      "cheshire-dma-submit/%u", t);
		if (IS_ERR(task[t])) {
			ret = PTR_ERR(task[t]);
			task[t] = NULL;
			thread_failures++;
			goto stop;
		}
	}
	complete_all(&start);
	for (t = 0; t < THREADS; t++) {
		if (!wait_for_completion_timeout(&thread[t].done,
						 msecs_to_jiffies(TEST_TIMEOUT_MS))) {
			timeouts++;
			ret = -ETIMEDOUT;
		} else if (thread[t].ret) {
			thread_failures++;
			ret = thread[t].ret;
		}
	}
	if (ret)
		goto stop;
	concurrent_submitted = THREADS * JOBS_PER_THREAD;
	dma_async_issue_pending(chan);
	for (t = 0; t < THREADS; t++) {
		for (i = 0; i < JOBS_PER_THREAD; i++) {
			ret = wait_transfer(&thread[t].ctx[i]);
			if (ret)
				goto stop;
		}
	}
	dmaengine_synchronize(chan);
	for (t = 0; t < THREADS; t++) {
		for (i = 0; i < JOBS_PER_THREAD; i++) {
			struct transfer_ctx *one = &thread[t].ctx[i];

			concurrent_completed++;
			if (one->result != DMA_TRANS_NOERROR || one->residue)
				ret = -EIO;
			if (finish_clean(chan, one, true))
				ret = -EIO;
			else
				concurrent_checks++;
		}
	}
	for (t = 0; t < THREADS; t++)
		if (task[t])
			kthread_stop(task[t]);
	kfree(ctx);
	return ret;

stop:
	complete_all(&start);
	for (t = 0; t < THREADS; t++)
		if (task[t])
			kthread_stop(task[t]);
	dmaengine_terminate_sync(chan);
	for (t = 0; t < THREADS; t++) {
		for (i = 0; i < thread[t].prepared; i++)
			cleanup_context(chan, &thread[t].ctx[i]);
	}
	kfree(ctx);
	return ret;
}

static int run_error_case(struct device *client_dev, struct dma_chan *chan,
			  const struct error_case *test, unsigned int index)
{
	struct device *dev = dmaengine_get_dma_device(chan);
	struct dma_async_tx_descriptor *tx;
	struct transfer_ctx ctx = { };
	dma_addr_t src_dma = 0, dst_dma = 0;
	bool src_resource = false, dst_resource = false;
	u32 expected_residue;
	int ret = 0;

	init_completion(&ctx.done);
	ctx.result = DMA_TRANS_ABORTED;
	ctx.residue = ~0U;
	if (test->kind == ERROR_READ) {
		src_dma = dma_map_resource(dev, test->addr, ERROR_LEN,
					   DMA_TO_DEVICE, 0);
		if (dma_mapping_error(dev, src_dma))
			return -EIO;
		src_resource = true;
	} else {
		ret = scratch_alloc(&ctx.src, ERROR_LEN, DMA_TO_DEVICE, true,
				    0xa0 + index);
		if (ret)
			goto out;
		ret = scratch_map(dev, &ctx.src);
		if (ret)
			goto out;
		src_dma = ctx.src.dma_base + L1_CACHE_BYTES;
	}

	if (test->kind == ERROR_WRITE) {
		dst_dma = dma_map_resource(dev, test->addr, ERROR_LEN,
					   DMA_FROM_DEVICE, 0);
		if (dma_mapping_error(dev, dst_dma)) {
			ret = -EIO;
			goto out;
		}
		dst_resource = true;
	} else {
		ret = scratch_alloc(&ctx.dst, ERROR_LEN, DMA_FROM_DEVICE, false, 0);
		if (ret)
			goto out;
		ret = scratch_map(dev, &ctx.dst);
		if (ret)
			goto out;
		dst_dma = ctx.dst.dma_base + L1_CACHE_BYTES;
	}

	tx = dmaengine_prep_dma_memcpy(chan, dst_dma, src_dma, ERROR_LEN,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!tx) {
		ret = -EIO;
		goto out;
	}
	tx->callback_result = transfer_callback;
	tx->callback_param = &ctx;
	ctx.cookie = dmaengine_submit(tx);
	ret = dma_submit_error(ctx.cookie);
	if (ret)
		goto out;
	error_submitted++;
	dma_async_issue_pending(chan);
	ret = wait_transfer(&ctx);
	if (ret) {
		dmaengine_terminate_sync(chan);
		goto out;
	}
	dmaengine_synchronize(chan);
	error_completed++;
	expected_residue = test->expected == DMA_TRANS_NOERROR ? 0 : ERROR_LEN;
	if (ctx.result != test->expected || ctx.residue != expected_residue) {
		error_mismatch++;
		ret = -EIO;
	}
	switch (ctx.result) {
	case DMA_TRANS_NOERROR:
		error_success++;
		break;
	case DMA_TRANS_READ_FAILED:
		error_read_failed++;
		break;
	case DMA_TRANS_WRITE_FAILED:
		error_write_failed++;
		break;
	case DMA_TRANS_ABORTED:
		error_aborted++;
		break;
	}

out:
	if (dst_resource)
		dma_unmap_resource(dev, dst_dma, ERROR_LEN, DMA_FROM_DEVICE, 0);
	scratch_unmap(dev, &ctx.dst);
	if (src_resource)
		dma_unmap_resource(dev, src_dma, ERROR_LEN, DMA_TO_DEVICE, 0);
	scratch_unmap(dev, &ctx.src);
	if (ctx.src.allocation && !scratch_guards_ok(&ctx.src)) {
		guard_failures++;
		ret = -EIO;
	}
	if (ctx.dst.allocation && !scratch_guards_ok(&ctx.dst)) {
		guard_failures++;
		ret = -EIO;
	}
	if (ctx.src.allocation && !scratch_source_ok(&ctx.src)) {
		payload_failures++;
		ret = -EIO;
	}
	if (!ret && test->kind == ERROR_CLEAN) {
		if (memcmp(ctx.src.payload, ctx.dst.payload, ERROR_LEN)) {
			payload_failures++;
			ret = -EIO;
		} else {
			error_clean_checks++;
		}
	}
	dev_info(client_dev,
		 "error-job=%s result=%u expected=%u residue=%u rc=%d\n",
		 test->name, ctx.result, test->expected, ctx.residue, ret);
	scratch_free(&ctx.dst);
	scratch_free(&ctx.src);
	return ret;
}

static int run_error_group(struct platform_device *pdev, struct dma_chan *chan)
{
	struct resource *slverr;
	struct resource *decerr;
	struct error_case test[ERROR_JOBS];
	unsigned int i;

	slverr = platform_get_resource_byname(pdev, IORESOURCE_MEM, "slverr");
	decerr = platform_get_resource_byname(pdev, IORESOURCE_MEM, "decerr");
	if (!slverr || !decerr)
		return -EINVAL;
	test[0] = (struct error_case){ "clean-0", ERROR_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	test[1] = (struct error_case){ "read-slverr", ERROR_READ,
		DMA_TRANS_READ_FAILED, slverr->start };
	test[2] = (struct error_case){ "clean-1", ERROR_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	test[3] = (struct error_case){ "write-slverr", ERROR_WRITE,
		DMA_TRANS_WRITE_FAILED, slverr->start };
	test[4] = (struct error_case){ "clean-2", ERROR_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	test[5] = (struct error_case){ "read-decerr", ERROR_READ,
		DMA_TRANS_READ_FAILED, decerr->start };
	test[6] = (struct error_case){ "clean-3", ERROR_CLEAN,
		DMA_TRANS_NOERROR, 0 };
	test[7] = (struct error_case){ "write-decerr", ERROR_WRITE,
		DMA_TRANS_WRITE_FAILED, decerr->start };
	test[8] = (struct error_case){ "clean-4", ERROR_CLEAN,
		DMA_TRANS_NOERROR, 0 };

	for (i = 0; i < ERROR_JOBS; i++) {
		int ret = run_error_case(&pdev->dev, chan, &test[i], i);

		if (ret)
			return ret;
	}
	return 0;
}

static int run_terminate_group(struct dma_chan *chan)
{
	struct transfer_ctx *ctx;
	unsigned int prepared = 0;
	unsigned int i;
	int callbacks_before;
	int ret = 0;

	ctx = kcalloc(TERMINATE_JOBS, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	for (i = 0; i < TERMINATE_JOBS; i++) {
		size_t len = i ? 64 + i : TERMINATE_LEN;

		ret = prepare_clean(chan, &ctx[i], len, 0xd0 + i);
		if (ret)
			goto out_terminate;
		prepared++;
		terminate_submitted++;
	}
	callbacks_before = atomic_read(&all_callbacks);
	dma_async_issue_pending(chan);
	ret = dmaengine_terminate_sync(chan);
	if (ret)
		goto out;
	terminate_callbacks = atomic_read(&all_callbacks) - callbacks_before;
	if (terminate_callbacks) {
		ret = -EIO;
		goto out;
	}
	for (i = 0; i < TERMINATE_JOBS; i++) {
		struct device *dev = dmaengine_get_dma_device(chan);

		scratch_unmap(dev, &ctx[i].dst);
		scratch_unmap(dev, &ctx[i].src);
		if (!scratch_guards_ok(&ctx[i].src) ||
		    !scratch_guards_ok(&ctx[i].dst)) {
			guard_failures++;
			ret = -EIO;
		}
		if (!scratch_source_ok(&ctx[i].src)) {
			payload_failures++;
			ret = -EIO;
		}
		if (!i && !memcmp(ctx[i].src.payload, ctx[i].dst.payload,
				  ctx[i].src.len)) {
			payload_failures++;
			ret = -EIO;
		}
		if (i && !scratch_is_fill(&ctx[i].dst)) {
			payload_failures++;
			ret = -EIO;
		}
		if (!ret)
			terminate_checks++;
		scratch_free(&ctx[i].dst);
		scratch_free(&ctx[i].src);
	}
	kfree(ctx);
	return ret;

out_terminate:
	dmaengine_terminate_sync(chan);
out:
	for (i = 0; i < prepared; i++)
		cleanup_context(chan, &ctx[i]);
	kfree(ctx);
	return ret;
}

static int run_recovery(struct dma_chan *chan)
{
	struct transfer_ctx ctx;
	int ret;

	ret = prepare_clean(chan, &ctx, 257, 0xf1);
	if (ret) {
		cleanup_context(chan, &ctx);
		return ret;
	}
	dma_async_issue_pending(chan);
	ret = wait_transfer(&ctx);
	if (ret) {
		dmaengine_terminate_sync(chan);
		cleanup_context(chan, &ctx);
		return ret;
	}
	dmaengine_synchronize(chan);
	if (ctx.result != DMA_TRANS_NOERROR || ctx.residue)
		ret = -EIO;
	if (finish_clean(chan, &ctx, true))
		ret = -EIO;
	if (!ret)
		recovery_checks++;
	return ret;
}

static int cheshire_irq_test_probe(struct platform_device *pdev)
{
	struct dma_chan *chan;
	unsigned long cache_before;
	int ret;

	cache_before = riscv_cheshire_cache_ops_count();
	chan = dma_request_chan(&pdev->dev, "memcpy");
	if (IS_ERR(chan))
		return dev_err_probe(&pdev->dev, PTR_ERR(chan),
				     "failed to request memcpy channel\n");

	ret = run_serial_group(chan);
	if (!ret)
		ret = run_queue_group(chan);
	if (!ret)
		ret = run_concurrent_group(chan);
	if (!ret)
		ret = run_error_group(pdev, chan);
	if (!ret)
		ret = run_terminate_group(chan);
	if (!ret)
		ret = run_recovery(chan);
	if (ret)
		dmaengine_terminate_sync(chan);
	dmaengine_synchronize(chan);
	dma_release_channel(chan);

	cache_ops_delta = riscv_cheshire_cache_ops_count() - cache_before;
	if (!ret && cache_ops_delta != EXPECTED_CACHE_OPS)
		ret = -EIO;
	if (!ret && (guard_failures || payload_failures ||
		     callback_duplicates || timeouts || queue_order_failures ||
		     thread_failures || error_mismatch))
		ret = -EIO;
	test_rc = ret;
	pass = !ret;
	platform_set_drvdata(pdev, (void *)(long)ret);
	dev_info(&pdev->dev,
		 "summary pass=%lu rc=%ld serial=%lu/%lu/%lu queue=%lu/%lu/%lu concurrent=%lu/%lu/%lu errors=%lu/%lu clean=%lu read=%lu write=%lu abort=%lu terminate=%lu callbacks=%lu checks=%lu recovery=%lu cache_ops=%lu\n",
		 pass, test_rc, serial_submitted, serial_completed, serial_checks,
		 queue_submitted, queue_completed, queue_checks,
		 concurrent_submitted, concurrent_completed, concurrent_checks,
		 error_submitted, error_completed, error_success,
		 error_read_failed, error_write_failed, error_aborted,
		 terminate_submitted, terminate_callbacks, terminate_checks,
		 recovery_checks, cache_ops_delta);
	if (pass)
		dev_info(&pdev->dev, "FPGA-LINUX-DMA-IRQ-CLIENT-PASS\n");
	return 0;
}

static const struct of_device_id cheshire_irq_test_of_match[] = {
	{ .compatible = "openai,cheshire-idma-irq-test" },
	{ }
};
MODULE_DEVICE_TABLE(of, cheshire_irq_test_of_match);

static struct platform_driver cheshire_irq_test_driver = {
	.probe = cheshire_irq_test_probe,
	.driver = {
		.name = "cheshire-idma-irq-test",
		.of_match_table = cheshire_irq_test_of_match,
	},
};
module_platform_driver(cheshire_irq_test_driver);

MODULE_DESCRIPTION("Bounded Cheshire iDMA IRQ/queue/abort DMAengine client");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
