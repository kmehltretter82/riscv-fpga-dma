// SPDX-License-Identifier: GPL-2.0-only
/* Bounded DMA-mapping matrix for the Cheshire iDMA DMAengine provider. */

#include <linux/cache.h>
#include <linux/completion.h>
#include <linux/dma-direct.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/gfp.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/swiotlb.h>
#include <asm/dma-noncoherent.h>
#include <asm/io.h>

#define TEST_TIMEOUT_MS		1000
#define SG_ENTRIES		265
#define SG_OFFSET		L1_CACHE_BYTES
#define SG_LENGTH		(PAGE_SIZE - 2 * L1_CACHE_BYTES)
#define SG_TOTAL_BYTES		((size_t)SG_ENTRIES * SG_LENGTH)
#define DIRECT_LARGE_LENGTH	(SZ_1M + 257)
#define DIRECT_SINGLE_JOBS	5
#define BOUNCE_SINGLE_JOBS	4
#define COHERENT_JOBS		2
#define DIRECT_HW_JOBS		(DIRECT_SINGLE_JOBS + SG_ENTRIES + COHERENT_JOBS)
#define BOUNCE_HW_JOBS		(BOUNCE_SINGLE_JOBS + SG_ENTRIES + COHERENT_JOBS)
#define DIRECT_CACHE_OPS	(3 * DIRECT_SINGLE_JOBS + 3 * SG_ENTRIES + 4)
#define BOUNCE_CACHE_OPS	(3 * BOUNCE_SINGLE_JOBS + 3 * SG_ENTRIES + 4)
#define PRE_GUARD		0xa5
#define POST_GUARD		0x5a
#define DST_FILL		0xcc

struct map_scratch {
	u8 *allocation;
	u8 *base;
	u8 *payload;
	size_t allocation_size;
	size_t payload_offset;
	size_t payload_len;
	size_t span;
	dma_addr_t dma_base;
	enum dma_data_direction direction;
	bool exact_pages;
	bool mapped;
	bool source;
	u8 seed;
};

struct map_job {
	struct completion done;
	enum dmaengine_tx_result result;
	u32 residue;
	dma_cookie_t cookie;
	unsigned int callbacks;
};

struct single_case {
	const char *name;
	size_t len;
	size_t src_offset;
	size_t dst_offset;
	bool direct_only;
	bool require_nonpage;
	bool require_unaligned;
	size_t boundary;
};

struct sg_side {
	struct scatterlist *sgl;
	struct page **pages;
	int mapped_nents;
	enum dma_data_direction direction;
	bool source;
};

struct coherent_side {
	u8 *base;
	u8 *payload;
	dma_addr_t dma_base;
	size_t allocation_size;
	size_t payload_offset;
	size_t payload_len;
	bool source;
	u8 seed;
};

static bool expect_force;
module_param(expect_force, bool, 0444);
MODULE_PARM_DESC(expect_force, "Require every streaming map to use SWIOTLB");

static unsigned long pass;
static long test_rc;
static unsigned long force_detected;
static unsigned long hw_jobs;
static unsigned long callbacks;
static unsigned long callback_failures;
static unsigned long cookie_failures;
static unsigned long timeouts;
static unsigned long guard_failures;
static unsigned long payload_failures;
static unsigned long mapping_failures;
static unsigned long mapping_proofs;
static unsigned long bounce_source_checks;
static unsigned long single_jobs;
static unsigned long single_bytes;
static unsigned long nonpage_cases;
static unsigned long unaligned_cases;
static unsigned long cross_4k_cases;
static unsigned long cross_64k_cases;
static unsigned long cross_1m_cases;
static unsigned long sg_original_nents;
static unsigned long sg_source_mapped_nents;
static unsigned long sg_destination_mapped_nents;
static unsigned long sg_chunks;
static unsigned long sg_bytes;
static unsigned long sg_checks;
static unsigned long coherent_jobs;
static unsigned long coherent_bytes;
static unsigned long coherent_checks;
static unsigned long coherent_nonbounce_proofs;
static unsigned long max_mapping_size_seen;
static unsigned long cache_ops_before;
static unsigned long cache_ops_delta;

module_param(pass, ulong, 0444);
module_param(test_rc, long, 0444);
module_param(force_detected, ulong, 0444);
module_param(hw_jobs, ulong, 0444);
module_param(callbacks, ulong, 0444);
module_param(callback_failures, ulong, 0444);
module_param(cookie_failures, ulong, 0444);
module_param(timeouts, ulong, 0444);
module_param(guard_failures, ulong, 0444);
module_param(payload_failures, ulong, 0444);
module_param(mapping_failures, ulong, 0444);
module_param(mapping_proofs, ulong, 0444);
module_param(bounce_source_checks, ulong, 0444);
module_param(single_jobs, ulong, 0444);
module_param(single_bytes, ulong, 0444);
module_param(nonpage_cases, ulong, 0444);
module_param(unaligned_cases, ulong, 0444);
module_param(cross_4k_cases, ulong, 0444);
module_param(cross_64k_cases, ulong, 0444);
module_param(cross_1m_cases, ulong, 0444);
module_param(sg_original_nents, ulong, 0444);
module_param(sg_source_mapped_nents, ulong, 0444);
module_param(sg_destination_mapped_nents, ulong, 0444);
module_param(sg_chunks, ulong, 0444);
module_param(sg_bytes, ulong, 0444);
module_param(sg_checks, ulong, 0444);
module_param(coherent_jobs, ulong, 0444);
module_param(coherent_bytes, ulong, 0444);
module_param(coherent_checks, ulong, 0444);
module_param(coherent_nonbounce_proofs, ulong, 0444);
module_param(max_mapping_size_seen, ulong, 0444);
module_param(cache_ops_before, ulong, 0444);
module_param(cache_ops_delta, ulong, 0444);

static u8 payload_byte(u8 seed, size_t offset)
{
	return (u8)(seed + offset * 37u + (offset >> 3));
}

static u8 sg_payload_byte(unsigned int entry, size_t offset)
{
	return payload_byte((u8)(0x21 + entry * 13u), offset);
}

static bool crosses_boundary(dma_addr_t address, size_t length,
			     size_t boundary)
{
	u64 first;
	u64 last;

	if (!length || !boundary)
		return false;
	first = address / boundary;
	last = (address + length - 1) / boundary;
	return first != last;
}

static void map_job_callback(void *parameter,
			     const struct dmaengine_result *result)
{
	struct map_job *job = parameter;

	job->result = result->result;
	job->residue = result->residue;
	job->callbacks++;
	callbacks++;
	complete(&job->done);
}

static int submit_job(struct dma_chan *chan, struct map_job *job,
		      dma_addr_t destination, dma_addr_t source, size_t length)
{
	struct dma_async_tx_descriptor *tx;

	memset(job, 0, sizeof(*job));
	init_completion(&job->done);
	job->result = DMA_TRANS_ABORTED;
	job->residue = ~0U;
	tx = dmaengine_prep_dma_memcpy(chan, destination, source, length,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!tx)
		return -EIO;
	tx->callback_result = map_job_callback;
	tx->callback_param = job;
	job->cookie = dmaengine_submit(tx);
	return dma_submit_error(job->cookie);
}

static int wait_job(struct dma_chan *chan, struct map_job *job)
{
	enum dma_status status;

	if (!wait_for_completion_timeout(&job->done,
					 msecs_to_jiffies(TEST_TIMEOUT_MS))) {
		timeouts++;
		return -ETIMEDOUT;
	}
	if (job->callbacks != 1 || job->result != DMA_TRANS_NOERROR ||
	    job->residue) {
		callback_failures++;
		return -EIO;
	}
	status = dma_async_is_tx_complete(chan, job->cookie, NULL, NULL);
	if (status != DMA_COMPLETE) {
		cookie_failures++;
		return -EIO;
	}
	return 0;
}

static int scratch_alloc(struct map_scratch *scratch, size_t payload_len,
			 size_t payload_offset,
			 enum dma_data_direction direction, bool source,
			 u8 seed, bool exact_pages)
{
	gfp_t exact_gfp = GFP_KERNEL | __GFP_ZERO;
	size_t allocation_size;
	size_t raw_size;
	size_t i;

	memset(scratch, 0, sizeof(*scratch));
	scratch->payload_len = payload_len;
	scratch->payload_offset = payload_offset;
	scratch->direction = direction;
	scratch->source = source;
	scratch->seed = seed;
	scratch->exact_pages = exact_pages;
	raw_size = ALIGN(payload_offset + payload_len + L1_CACHE_BYTES,
			 L1_CACHE_BYTES);
	scratch->allocation_size = raw_size + L1_CACHE_BYTES - 1;
	allocation_size = scratch->allocation_size;
	if (exact_pages)
		scratch->allocation = alloc_pages_exact(allocation_size, exact_gfp);
	else
		scratch->allocation = kmalloc(scratch->allocation_size, GFP_KERNEL);
	if (!scratch->allocation)
		return -ENOMEM;
	scratch->base = PTR_ALIGN(scratch->allocation, L1_CACHE_BYTES);
	scratch->payload = scratch->base + payload_offset;
	scratch->span = raw_size;
	memset(scratch->base, PRE_GUARD, payload_offset);
	if (source) {
		for (i = 0; i < payload_len; i++)
			scratch->payload[i] = payload_byte(seed, i);
	} else {
		memset(scratch->payload, DST_FILL, payload_len);
	}
	memset(scratch->payload + payload_len, POST_GUARD,
	       scratch->span - payload_offset - payload_len);
	return 0;
}

static void scratch_free(struct map_scratch *scratch)
{
	if (scratch->exact_pages)
		free_pages_exact(scratch->allocation, scratch->allocation_size);
	else
		kfree(scratch->allocation);
	memset(scratch, 0, sizeof(*scratch));
}

static int prove_streaming_mapping(struct device *dev,
				   struct map_scratch *scratch)
{
	phys_addr_t dma_phys = dma_to_phys(dev, scratch->dma_base);
	phys_addr_t original_phys = virt_to_phys(scratch->base);
	struct io_tlb_pool *first;
	struct io_tlb_pool *last;

	first = swiotlb_find_pool(dev, dma_phys);
	last = swiotlb_find_pool(dev, dma_phys + scratch->span - 1);
	if (scratch->span > dma_max_mapping_size(dev))
		goto fail;
	if (expect_force) {
		if (!first || first != last || dma_phys == original_phys)
			goto fail;
		if (scratch->source &&
		    memcmp(phys_to_virt(dma_phys) + scratch->payload_offset,
			   scratch->payload, scratch->payload_len))
			goto fail;
		if (scratch->source)
			bounce_source_checks++;
	} else if (first || last || dma_phys != original_phys) {
		goto fail;
	}
	mapping_proofs++;
	return 0;

fail:
	mapping_failures++;
	return -EIO;
}

static int scratch_map(struct device *dev, struct map_scratch *scratch)
{
	scratch->dma_base = dma_map_single(dev, scratch->base, scratch->span,
					   scratch->direction);
	if (dma_mapping_error(dev, scratch->dma_base))
		return -EIO;
	scratch->mapped = true;
	return prove_streaming_mapping(dev, scratch);
}

static void scratch_unmap(struct device *dev, struct map_scratch *scratch)
{
	if (!scratch->mapped)
		return;
	dma_unmap_single(dev, scratch->dma_base, scratch->span,
			 scratch->direction);
	scratch->mapped = false;
}

static bool scratch_guards_ok(const struct map_scratch *scratch)
{
	size_t i;

	for (i = 0; i < scratch->payload_offset; i++)
		if (scratch->base[i] != PRE_GUARD)
			return false;
	for (i = scratch->payload_offset + scratch->payload_len;
	     i < scratch->span; i++)
		if (scratch->base[i] != POST_GUARD)
			return false;
	return true;
}

static bool scratch_source_ok(const struct map_scratch *scratch)
{
	size_t i;

	for (i = 0; i < scratch->payload_len; i++)
		if (scratch->payload[i] != payload_byte(scratch->seed, i))
			return false;
	return true;
}

static int run_single_case(struct dma_chan *chan,
			   const struct single_case *test, unsigned int index)
{
	struct device *dev = dmaengine_get_dma_device(chan);
	struct map_scratch source = { };
	struct map_scratch destination = { };
	struct map_job job;
	bool exact = test->len > SZ_1M;
	int ret;

	if (test->direct_only && expect_force)
		return 0;
	ret = scratch_alloc(&source, test->len, test->src_offset,
			    DMA_TO_DEVICE, true, 0x30 + index, exact);
	if (ret)
		goto out;
	ret = scratch_alloc(&destination, test->len, test->dst_offset,
			    DMA_FROM_DEVICE, false, 0, exact);
	if (ret)
		goto out;
	ret = scratch_map(dev, &source);
	if (ret)
		goto out;
	ret = scratch_map(dev, &destination);
	if (ret)
		goto out;

	if (test->require_nonpage) {
		if (IS_ALIGNED(virt_to_phys(source.payload), PAGE_SIZE) ||
		    IS_ALIGNED(virt_to_phys(destination.payload), PAGE_SIZE)) {
			mapping_failures++;
			ret = -EIO;
			goto out;
		}
		nonpage_cases++;
	}
	if (test->require_unaligned) {
		if (IS_ALIGNED(source.dma_base + source.payload_offset,
			       L1_CACHE_BYTES) ||
		    IS_ALIGNED(destination.dma_base + destination.payload_offset,
			       L1_CACHE_BYTES)) {
			mapping_failures++;
			ret = -EIO;
			goto out;
		}
		unaligned_cases++;
	}
	if (test->boundary &&
	    (!crosses_boundary(source.dma_base + source.payload_offset,
			       test->len, test->boundary) ||
	     !crosses_boundary(destination.dma_base + destination.payload_offset,
			       test->len, test->boundary))) {
		mapping_failures++;
		ret = -EIO;
		goto out;
	}
	if (test->boundary == SZ_4K)
		cross_4k_cases++;
	else if (test->boundary == SZ_64K)
		cross_64k_cases++;
	else if (test->boundary == SZ_1M)
		cross_1m_cases++;

	ret = submit_job(chan, &job,
			 destination.dma_base + destination.payload_offset,
			 source.dma_base + source.payload_offset, test->len);
	if (ret)
		goto out;
	hw_jobs++;
	dma_async_issue_pending(chan);
	ret = wait_job(chan, &job);
	if (ret) {
		dmaengine_terminate_sync(chan);
		goto out;
	}
	dmaengine_synchronize(chan);
	single_jobs++;
	single_bytes += test->len;

out:
	scratch_unmap(dev, &destination);
	scratch_unmap(dev, &source);
	if (source.allocation && !scratch_guards_ok(&source)) {
		guard_failures++;
		ret = -EIO;
	}
	if (destination.allocation && !scratch_guards_ok(&destination)) {
		guard_failures++;
		ret = -EIO;
	}
	if (source.allocation && !scratch_source_ok(&source)) {
		payload_failures++;
		ret = -EIO;
	}
	if (source.allocation && destination.allocation && !ret &&
	    memcmp(source.payload, destination.payload, test->len)) {
		payload_failures++;
		ret = -EIO;
	}
	if (destination.allocation)
		scratch_free(&destination);
	if (source.allocation)
		scratch_free(&source);
	return ret;
}

static int run_single_group(struct dma_chan *chan)
{
	static const struct single_case tests[] = {
		{ "nonpage-subpage", 257, L1_CACHE_BYTES, L1_CACHE_BYTES,
		  false, true, false, 0 },
		{ "page-byte-unaligned", PAGE_SIZE, L1_CACHE_BYTES + 1,
		  L1_CACHE_BYTES + 3, false, false, true, 0 },
		{ "cross-4k", PAGE_SIZE + 1, L1_CACHE_BYTES,
		  L1_CACHE_BYTES, false, false, false, SZ_4K },
		{ "cross-64k", SZ_64K + 1, L1_CACHE_BYTES,
		  L1_CACHE_BYTES, false, false, false, SZ_64K },
		{ "direct-cross-1m", DIRECT_LARGE_LENGTH, L1_CACHE_BYTES,
		  L1_CACHE_BYTES, true, false, false, SZ_1M },
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(tests); i++) {
		int ret = run_single_case(chan, &tests[i], i);

		if (ret)
			return ret;
	}
	return 0;
}

static int sg_side_alloc(struct sg_side *side,
			 enum dma_data_direction direction, bool source)
{
	unsigned int i;

	memset(side, 0, sizeof(*side));
	side->direction = direction;
	side->source = source;
	side->sgl = kcalloc(SG_ENTRIES, sizeof(*side->sgl), GFP_KERNEL);
	side->pages = kcalloc(SG_ENTRIES, sizeof(*side->pages), GFP_KERNEL);
	if (!side->sgl || !side->pages)
		return -ENOMEM;
	sg_init_table(side->sgl, SG_ENTRIES);
	for (i = 0; i < SG_ENTRIES; i++) {
		u8 *data;
		size_t j;

		side->pages[i] = alloc_page(GFP_KERNEL);
		if (!side->pages[i])
			return -ENOMEM;
		data = page_address(side->pages[i]);
		memset(data, PRE_GUARD, SG_OFFSET);
		if (source) {
			for (j = 0; j < SG_LENGTH; j++)
				data[SG_OFFSET + j] = sg_payload_byte(i, j);
		} else {
			memset(data + SG_OFFSET, DST_FILL, SG_LENGTH);
		}
		memset(data + SG_OFFSET + SG_LENGTH, POST_GUARD,
		       PAGE_SIZE - SG_OFFSET - SG_LENGTH);
		sg_set_page(&side->sgl[i], side->pages[i], SG_LENGTH, SG_OFFSET);
	}
	return 0;
}

static void sg_side_free(struct sg_side *side)
{
	unsigned int i;

	if (side->pages)
		for (i = 0; i < SG_ENTRIES; i++)
			if (side->pages[i])
				__free_page(side->pages[i]);
	kfree(side->pages);
	kfree(side->sgl);
	memset(side, 0, sizeof(*side));
}

static int prove_sg_mapping(struct device *dev, struct sg_side *side)
{
	struct scatterlist *sg;
	int i;

	if (side->mapped_nents != SG_ENTRIES)
		goto fail;
	for_each_sg(side->sgl, sg, side->mapped_nents, i) {
		phys_addr_t dma_phys = dma_to_phys(dev, sg_dma_address(sg));
		phys_addr_t original_phys = sg_phys(sg);
		struct io_tlb_pool *first;
		struct io_tlb_pool *last;

		first = swiotlb_find_pool(dev, dma_phys);
		last = swiotlb_find_pool(dev, dma_phys + sg_dma_len(sg) - 1);
		if (!sg_dma_len(sg) ||
		    sg_dma_len(sg) > dma_max_mapping_size(dev))
			goto fail;
		if (expect_force) {
			if (!first || first != last || dma_phys == original_phys)
				goto fail;
			if (side->source &&
			    memcmp(phys_to_virt(dma_phys),
				   page_address(side->pages[i]) + SG_OFFSET,
				   SG_LENGTH))
				goto fail;
			if (side->source)
				bounce_source_checks++;
		} else if (first || last || dma_phys != original_phys) {
			goto fail;
		}
		mapping_proofs++;
	}
	return 0;

fail:
	mapping_failures++;
	return -EIO;
}

static int sg_side_map(struct device *dev, struct sg_side *side)
{
	side->mapped_nents = dma_map_sg(dev, side->sgl, SG_ENTRIES,
					side->direction);
	if (!side->mapped_nents)
		return -EIO;
	return prove_sg_mapping(dev, side);
}

static void sg_side_unmap(struct device *dev, struct sg_side *side)
{
	if (!side->mapped_nents)
		return;
	dma_unmap_sg(dev, side->sgl, SG_ENTRIES, side->direction);
	side->mapped_nents = 0;
}

static int sg_verify(const struct sg_side *source,
		     const struct sg_side *destination)
{
	unsigned int i;

	for (i = 0; i < SG_ENTRIES; i++) {
		const u8 *src = page_address(source->pages[i]);
		const u8 *dst = page_address(destination->pages[i]);
		size_t j;

		for (j = 0; j < SG_OFFSET; j++)
			if (src[j] != PRE_GUARD || dst[j] != PRE_GUARD)
				goto guard_fail;
		for (j = SG_OFFSET + SG_LENGTH; j < PAGE_SIZE; j++)
			if (src[j] != POST_GUARD || dst[j] != POST_GUARD)
				goto guard_fail;
		for (j = 0; j < SG_LENGTH; j++) {
			u8 expected = sg_payload_byte(i, j);

			if (src[SG_OFFSET + j] != expected ||
			    dst[SG_OFFSET + j] != expected)
				goto payload_fail;
		}
	}
	return 0;

guard_fail:
	guard_failures++;
	return -EIO;
payload_fail:
	payload_failures++;
	return -EIO;
}

static int run_sg_group(struct dma_chan *chan)
{
	struct device *dev = dmaengine_get_dma_device(chan);
	struct sg_side source = { };
	struct sg_side destination = { };
	struct map_job *jobs = NULL;
	struct scatterlist *src_sg;
	struct scatterlist *dst_sg;
	size_t src_offset = 0;
	size_t dst_offset = 0;
	size_t submitted_bytes = 0;
	unsigned int prepared = 0;
	unsigned int capacity;
	unsigned int i;
	int ret;

	ret = sg_side_alloc(&source, DMA_TO_DEVICE, true);
	if (ret)
		goto out;
	ret = sg_side_alloc(&destination, DMA_FROM_DEVICE, false);
	if (ret)
		goto out;
	ret = sg_side_map(dev, &source);
	if (ret)
		goto out;
	ret = sg_side_map(dev, &destination);
	if (ret)
		goto out;

	sg_original_nents = SG_ENTRIES;
	sg_source_mapped_nents = source.mapped_nents;
	sg_destination_mapped_nents = destination.mapped_nents;
	capacity = source.mapped_nents + destination.mapped_nents;
	jobs = kcalloc(capacity, sizeof(*jobs), GFP_KERNEL);
	if (!jobs) {
		ret = -ENOMEM;
		goto out;
	}
	src_sg = source.sgl;
	dst_sg = destination.sgl;
	while (src_sg && dst_sg) {
		size_t src_remaining = sg_dma_len(src_sg) - src_offset;
		size_t dst_remaining = sg_dma_len(dst_sg) - dst_offset;
		size_t length = min(src_remaining, dst_remaining);

		if (!length || prepared >= capacity) {
			ret = -EIO;
			goto terminate;
		}
		ret = submit_job(chan, &jobs[prepared],
				 sg_dma_address(dst_sg) + dst_offset,
				 sg_dma_address(src_sg) + src_offset, length);
		if (ret)
			goto terminate;
		prepared++;
		hw_jobs++;
		submitted_bytes += length;
		src_offset += length;
		dst_offset += length;
		if (src_offset == sg_dma_len(src_sg)) {
			src_sg = sg_next(src_sg);
			src_offset = 0;
		}
		if (dst_offset == sg_dma_len(dst_sg)) {
			dst_sg = sg_next(dst_sg);
			dst_offset = 0;
		}
	}
	if (src_sg || dst_sg || submitted_bytes != SG_TOTAL_BYTES) {
		ret = -EIO;
		goto terminate;
	}
	dma_async_issue_pending(chan);
	for (i = 0; i < prepared; i++) {
		ret = wait_job(chan, &jobs[i]);
		if (ret)
			goto terminate;
	}
	dmaengine_synchronize(chan);
	sg_chunks = prepared;
	sg_bytes = submitted_bytes;
	ret = 0;
	goto out;

terminate:
	dmaengine_terminate_sync(chan);
out:
	sg_side_unmap(dev, &destination);
	sg_side_unmap(dev, &source);
	if (source.pages && destination.pages && !ret) {
		ret = sg_verify(&source, &destination);
		if (!ret)
			sg_checks = SG_ENTRIES;
	}
	kfree(jobs);
	sg_side_free(&destination);
	sg_side_free(&source);
	return ret;
}

static int coherent_side_alloc(struct device *dev,
			       struct coherent_side *side, size_t length,
			       size_t offset, bool source, u8 seed)
{
	size_t i;

	memset(side, 0, sizeof(*side));
	side->payload_len = length;
	side->payload_offset = offset;
	side->allocation_size = PAGE_ALIGN(offset + length + L1_CACHE_BYTES);
	side->source = source;
	side->seed = seed;
	side->base = dma_alloc_coherent(dev, side->allocation_size,
					&side->dma_base, GFP_KERNEL);
	if (!side->base)
		return -ENOMEM;
	if (swiotlb_find_pool(dev, dma_to_phys(dev, side->dma_base))) {
		mapping_failures++;
		return -EIO;
	}
	coherent_nonbounce_proofs++;
	side->payload = side->base + offset;
	memset(side->base, PRE_GUARD, offset);
	if (source) {
		for (i = 0; i < length; i++)
			side->payload[i] = payload_byte(seed, i);
	} else {
		memset(side->payload, DST_FILL, length);
	}
	memset(side->payload + length, POST_GUARD,
	       side->allocation_size - offset - length);
	return 0;
}

static void coherent_side_free(struct device *dev,
			       struct coherent_side *side)
{
	if (side->base)
		dma_free_coherent(dev, side->allocation_size, side->base,
				  side->dma_base);
	memset(side, 0, sizeof(*side));
}

static int coherent_verify(const struct coherent_side *source,
			   const struct coherent_side *destination)
{
	size_t i;

	for (i = 0; i < source->payload_offset; i++)
		if (source->base[i] != PRE_GUARD)
			goto guard_fail;
	for (i = 0; i < destination->payload_offset; i++)
		if (destination->base[i] != PRE_GUARD)
			goto guard_fail;
	for (i = source->payload_offset + source->payload_len;
	     i < source->allocation_size; i++)
		if (source->base[i] != POST_GUARD)
			goto guard_fail;
	for (i = destination->payload_offset + destination->payload_len;
	     i < destination->allocation_size; i++)
		if (destination->base[i] != POST_GUARD)
			goto guard_fail;
	for (i = 0; i < source->payload_len; i++) {
		u8 expected = payload_byte(source->seed, i);

		if (source->payload[i] != expected ||
		    destination->payload[i] != expected)
			goto payload_fail;
	}
	return 0;

guard_fail:
	guard_failures++;
	return -EIO;
payload_fail:
	payload_failures++;
	return -EIO;
}

static int run_coherent_case(struct dma_chan *chan, size_t length,
			     size_t source_offset, size_t destination_offset,
			     size_t boundary, u8 seed)
{
	struct device *dev = dmaengine_get_dma_device(chan);
	struct coherent_side source = { };
	struct coherent_side destination = { };
	struct map_job job;
	int ret;

	ret = coherent_side_alloc(dev, &source, length, source_offset, true,
				  seed);
	if (ret)
		goto out;
	ret = coherent_side_alloc(dev, &destination, length, destination_offset,
				  false, 0);
	if (ret)
		goto out;
	if (boundary &&
	    (!crosses_boundary(source.dma_base + source_offset, length,
			       boundary) ||
	     !crosses_boundary(destination.dma_base + destination_offset, length,
			       boundary))) {
		mapping_failures++;
		ret = -EIO;
		goto out;
	}
	/* Publish coherent source writes before ringing the DMA doorbell. */
	wmb();
	ret = submit_job(chan, &job, destination.dma_base + destination_offset,
			 source.dma_base + source_offset, length);
	if (ret)
		goto out;
	hw_jobs++;
	dma_async_issue_pending(chan);
	ret = wait_job(chan, &job);
	if (ret) {
		dmaengine_terminate_sync(chan);
		goto out;
	}
	dmaengine_synchronize(chan);
	/* Order DMA completion before reading the coherent destination. */
	rmb();
	ret = coherent_verify(&source, &destination);
	if (!ret) {
		coherent_jobs++;
		coherent_bytes += length;
		coherent_checks++;
	}

out:
	coherent_side_free(dev, &destination);
	coherent_side_free(dev, &source);
	return ret;
}

static int run_coherent_group(struct dma_chan *chan)
{
	int ret;

	ret = run_coherent_case(chan, 777, L1_CACHE_BYTES,
				L1_CACHE_BYTES + 1, 0, 0xb0);
	if (ret)
		return ret;
	return run_coherent_case(chan, SZ_64K + 1, L1_CACHE_BYTES,
				 L1_CACHE_BYTES, SZ_64K, 0xc0);
}

static int check_exact_results(void)
{
	unsigned long expected_singles = expect_force ? BOUNCE_SINGLE_JOBS :
		DIRECT_SINGLE_JOBS;
	unsigned long expected_jobs = expect_force ? BOUNCE_HW_JOBS :
		DIRECT_HW_JOBS;
	unsigned long expected_cache = expect_force ? BOUNCE_CACHE_OPS :
		DIRECT_CACHE_OPS;
	unsigned long expected_proofs = 2 * expected_singles + 2 * SG_ENTRIES;
	unsigned long expected_bounce_checks = expect_force ?
		BOUNCE_SINGLE_JOBS + SG_ENTRIES : 0;
	unsigned long expected_single_bytes = expect_force ? 73987 : 1122820;

	if (force_detected != expect_force || single_jobs != expected_singles ||
	    single_bytes != expected_single_bytes || nonpage_cases != 1 ||
	    unaligned_cases != 1 || cross_4k_cases != 1 ||
	    cross_64k_cases != 1 || cross_1m_cases != !expect_force ||
	    sg_original_nents != SG_ENTRIES ||
	    sg_source_mapped_nents != SG_ENTRIES ||
	    sg_destination_mapped_nents != SG_ENTRIES ||
	    sg_chunks != SG_ENTRIES || sg_bytes != SG_TOTAL_BYTES ||
	    sg_checks != SG_ENTRIES || coherent_jobs != COHERENT_JOBS ||
	    coherent_bytes != 66314 || coherent_checks != COHERENT_JOBS ||
	    coherent_nonbounce_proofs != 2 * COHERENT_JOBS ||
	    hw_jobs != expected_jobs || callbacks != expected_jobs ||
	    mapping_proofs != expected_proofs ||
	    bounce_source_checks != expected_bounce_checks ||
	    cache_ops_delta != expected_cache || callback_failures ||
	    cookie_failures || timeouts || guard_failures || payload_failures ||
	    mapping_failures)
		return -EIO;
	return 0;
}

static int cheshire_mapping_test_probe(struct platform_device *pdev)
{
	struct dma_chan *chan;
	struct device *dev;
	unsigned long cache_before;
	int ret;

	cache_before = riscv_cheshire_cache_ops_count();
	cache_ops_before = cache_before;
	chan = dma_request_chan(&pdev->dev, "memcpy");
	if (IS_ERR(chan))
		return dev_err_probe(&pdev->dev, PTR_ERR(chan),
				     "failed to request memcpy channel\n");
	dev = dmaengine_get_dma_device(chan);
	force_detected = is_swiotlb_force_bounce(dev);
	max_mapping_size_seen = dma_max_mapping_size(dev);
	if (force_detected != expect_force) {
		mapping_failures++;
		ret = -EIO;
		goto release;
	}

	ret = run_single_group(chan);
	if (!ret)
		ret = run_sg_group(chan);
	if (!ret)
		ret = run_coherent_group(chan);
	if (ret)
		dmaengine_terminate_sync(chan);
	dmaengine_synchronize(chan);

release:
	dma_release_channel(chan);
	cache_ops_delta = riscv_cheshire_cache_ops_count() - cache_before;
	if (!ret)
		ret = check_exact_results();
	test_rc = ret;
	pass = !ret;
	platform_set_drvdata(pdev, (void *)(long)ret);
	dev_info(&pdev->dev,
		 "summary pass=%lu rc=%ld force=%lu jobs=%lu callbacks=%lu singles=%lu bytes=%lu sg=%lu/%lu/%lu chunks=%lu bytes=%lu coherent=%lu bytes=%lu proofs=%lu bounce_checks=%lu cache_ops=%lu max_mapping=%lu\n",
		 pass, test_rc, force_detected, hw_jobs, callbacks, single_jobs,
		 single_bytes, sg_original_nents, sg_source_mapped_nents,
		 sg_destination_mapped_nents, sg_chunks, sg_bytes, coherent_jobs,
		 coherent_bytes, mapping_proofs, bounce_source_checks,
		 cache_ops_delta, max_mapping_size_seen);
	if (pass)
		dev_info(&pdev->dev,
			 expect_force ?
			 "FPGA-LINUX-DMA-MAPPING-SWIOTLB-CLIENT-PASS\n" :
			 "FPGA-LINUX-DMA-MAPPING-DIRECT-CLIENT-PASS\n");
	return 0;
}

static const struct of_device_id cheshire_mapping_test_of_match[] = {
	{ .compatible = "openai,cheshire-idma-mapping-test" },
	{ }
};
MODULE_DEVICE_TABLE(of, cheshire_mapping_test_of_match);

static struct platform_driver cheshire_mapping_test_driver = {
	.probe = cheshire_mapping_test_probe,
	.driver = {
		.name = "cheshire-idma-mapping-test",
		.of_match_table = cheshire_mapping_test_of_match,
	},
};
module_platform_driver(cheshire_mapping_test_driver);

MODULE_DESCRIPTION("Cheshire iDMA direct/SWIOTLB DMA-mapping matrix");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
