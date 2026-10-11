// SPDX-License-Identifier: GPL-2.0-only
/* Deliberate, bounded DMA-API misuse matrix for CONFIG_DMA_API_DEBUG. */

#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/gfp.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>

#define MAP_SIZE 256

static unsigned long pass;
static long test_rc;
static unsigned long cases;
static unsigned long cleanup;

module_param(pass, ulong, 0444);
module_param(test_rc, long, 0444);
module_param(cases, ulong, 0444);
module_param(cleanup, ulong, 0444);

static int alloc_buffer(void **buffer)
{
	*buffer = kzalloc(MAP_SIZE, GFP_KERNEL);
	return *buffer ? 0 : -ENOMEM;
}

/* Unmap without the required dma_mapping_error() query. */
static int unchecked_map_case(struct device *dev)
{
	dma_addr_t address;
	void *buffer;
	int ret;

	ret = alloc_buffer(&buffer);
	if (ret)
		return ret;
	address = dma_map_single(dev, buffer, MAP_SIZE, DMA_TO_DEVICE);
	/* Direct DMA cannot fail for this ordinary low-memory allocation. */
	if (address == DMA_MAPPING_ERROR) {
		kfree(buffer);
		return -EIO;
	}
	dma_unmap_single(dev, address, MAP_SIZE, DMA_TO_DEVICE);
	cleanup++;
	cases++;
	kfree(buffer);
	return 0;
}

/* Map 256 bytes, but claim only 128 bytes at unmap time. */
static int wrong_size_case(struct device *dev)
{
	dma_addr_t address;
	void *buffer;
	int ret;

	ret = alloc_buffer(&buffer);
	if (ret)
		return ret;
	address = dma_map_single(dev, buffer, MAP_SIZE, DMA_TO_DEVICE);
	if (dma_mapping_error(dev, address)) {
		kfree(buffer);
		return -EIO;
	}
	dma_unmap_single(dev, address, MAP_SIZE / 2, DMA_TO_DEVICE);
	cleanup++;
	cases++;
	kfree(buffer);
	return 0;
}

/* Sync a TO_DEVICE mapping with the opposite direction. */
static int wrong_direction_case(struct device *dev)
{
	dma_addr_t address;
	void *buffer;
	int ret;

	ret = alloc_buffer(&buffer);
	if (ret)
		return ret;
	address = dma_map_single(dev, buffer, MAP_SIZE, DMA_TO_DEVICE);
	if (dma_mapping_error(dev, address)) {
		kfree(buffer);
		return -EIO;
	}
	dma_sync_single_for_device(dev, address, MAP_SIZE, DMA_FROM_DEVICE);
	dma_unmap_single(dev, address, MAP_SIZE, DMA_TO_DEVICE);
	cleanup++;
	cases++;
	kfree(buffer);
	return 0;
}

/* Map two SG entries, but pass only one to the sync operation. */
static int wrong_sg_count_case(struct device *dev)
{
	struct scatterlist list[2];
	struct page *pages[2] = { NULL, NULL };
	int mapped;
	int ret = 0;

	pages[0] = alloc_page(GFP_KERNEL | __GFP_ZERO);
	pages[1] = alloc_page(GFP_KERNEL | __GFP_ZERO);
	if (!pages[0] || !pages[1]) {
		ret = -ENOMEM;
		goto free_pages;
	}
	sg_init_table(list, ARRAY_SIZE(list));
	sg_set_page(&list[0], pages[0], MAP_SIZE, 0);
	sg_set_page(&list[1], pages[1], MAP_SIZE, 0);
	mapped = dma_map_sg(dev, list, ARRAY_SIZE(list), DMA_TO_DEVICE);
	if (mapped != ARRAY_SIZE(list)) {
		if (mapped > 0)
			dma_unmap_sg(dev, list, ARRAY_SIZE(list), DMA_TO_DEVICE);
		ret = -EIO;
		goto free_pages;
	}
	dma_sync_sg_for_device(dev, list, 1, DMA_TO_DEVICE);
	dma_unmap_sg(dev, list, ARRAY_SIZE(list), DMA_TO_DEVICE);
	cleanup++;
	cases++;

free_pages:
	if (pages[1])
		__free_page(pages[1]);
	if (pages[0])
		__free_page(pages[0]);
	return ret;
}

/* Perform a correct unmap and then repeat the same unmap. */
static int double_unmap_case(struct device *dev)
{
	dma_addr_t address;
	void *buffer;
	int ret;

	ret = alloc_buffer(&buffer);
	if (ret)
		return ret;
	address = dma_map_single(dev, buffer, MAP_SIZE, DMA_TO_DEVICE);
	if (dma_mapping_error(dev, address)) {
		kfree(buffer);
		return -EIO;
	}
	dma_unmap_single(dev, address, MAP_SIZE, DMA_TO_DEVICE);
	dma_unmap_single(dev, address, MAP_SIZE, DMA_TO_DEVICE);
	cleanup++;
	cases++;
	kfree(buffer);
	return 0;
}

static int cheshire_api_negative_probe(struct platform_device *pdev)
{
	struct dma_chan *channel;
	struct device *dma_dev;
	int ret;

	channel = dma_request_chan(&pdev->dev, "memcpy");
	if (IS_ERR(channel)) {
		ret = PTR_ERR(channel);
		goto done;
	}
	dma_dev = dmaengine_get_dma_device(channel);

	ret = unchecked_map_case(dma_dev);
	if (!ret)
		ret = wrong_size_case(dma_dev);
	if (!ret)
		ret = wrong_direction_case(dma_dev);
	if (!ret)
		ret = wrong_sg_count_case(dma_dev);
	if (!ret)
		ret = double_unmap_case(dma_dev);

	dma_release_channel(channel);
done:
	test_rc = ret;
	pass = !ret && cases == 5 && cleanup == 5;
	dev_info(&pdev->dev,
		 "FPGA-LINUX-DMA-API-NEGATIVE-CLIENT pass=%lu rc=%ld cases=%lu cleanup=%lu\n",
		 pass, test_rc, cases, cleanup);
	return 0;
}

static const struct of_device_id cheshire_api_negative_of_match[] = {
	{ .compatible = "openai,cheshire-idma-api-negative" },
	{ }
};
MODULE_DEVICE_TABLE(of, cheshire_api_negative_of_match);

static struct platform_driver cheshire_api_negative_driver = {
	.probe = cheshire_api_negative_probe,
	.driver = {
		.name = "cheshire-idma-api-negative",
		.of_match_table = cheshire_api_negative_of_match,
	},
};
module_platform_driver(cheshire_api_negative_driver);

MODULE_DESCRIPTION("Deliberate Cheshire DMA-API-debug misuse matrix");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
