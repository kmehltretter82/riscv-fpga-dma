// SPDX-License-Identifier: GPL-2.0-only
/*
 * Investigation-only DMAengine provider for Cheshire's system iDMA.
 *
 * The current Cheshire wrapper exposes no completion interrupt.  One virtual
 * DMA channel therefore serializes descriptors in a workqueue and polls the
 * register frontend's DONE_ID.  This is sufficient to put the real RTL data
 * path below Linux dmatest and CONFIG_DMA_API_DEBUG; it is not an upstream
 * driver or a proposed device-tree ABI.
 */

#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_dma.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <asm/dma-noncoherent.h>

#include "virt-dma.h"

#define CHESHIRE_IDMA_CONF		0x000
#define CHESHIRE_IDMA_NEXT_ID		0x044
#define CHESHIRE_IDMA_DONE_ID		0x084
#define CHESHIRE_IDMA_DST_ADDR		0x0d0
#define CHESHIRE_IDMA_SRC_ADDR		0x0d8
#define CHESHIRE_IDMA_LENGTH		0x0e0

/* Hardware normally finishes a 4 KiB dmatest copy in far fewer polls. */
#define CHESHIRE_IDMA_MAX_POLLS		65536

struct cheshire_idma_desc {
	struct virt_dma_desc vd;
	dma_addr_t src;
	dma_addr_t dst;
	size_t len;
};

struct cheshire_idma {
	struct dma_device ddev;
	struct virt_dma_chan vc;
	struct work_struct work;
	void __iomem *base;
};

static unsigned long submitted;
static unsigned long completed;
static unsigned long timeouts;
module_param(submitted, ulong, 0444);
module_param(completed, ulong, 0444);
module_param(timeouts, ulong, 0444);
MODULE_PARM_DESC(submitted, "Descriptors launched through the iDMA frontend");
MODULE_PARM_DESC(completed, "Descriptors completed by the iDMA frontend");
MODULE_PARM_DESC(timeouts, "Descriptors which exceeded the bounded DONE_ID poll");

static int cheshire_idma_cache_ops_get(char *buf,
				       const struct kernel_param *kp)
{
	(void)kp;
	return sysfs_emit(buf, "%lu\n", riscv_cheshire_cache_ops_count());
}

static const struct kernel_param_ops cheshire_idma_cache_ops_param_ops = {
	.get = cheshire_idma_cache_ops_get,
};
module_param_cb(cache_ops, &cheshire_idma_cache_ops_param_ops, NULL, 0444);
MODULE_PARM_DESC(cache_ops, "Completed Cheshire noncoherent cache operations");

static struct cheshire_idma *to_cheshire_idma(struct dma_chan *chan)
{
	return container_of(to_virt_chan(chan), struct cheshire_idma, vc);
}

static struct cheshire_idma_desc *to_cheshire_desc(struct virt_dma_desc *vd)
{
	return container_of(vd, struct cheshire_idma_desc, vd);
}

static void cheshire_idma_desc_free(struct virt_dma_desc *vd)
{
	kfree(to_cheshire_desc(vd));
}

static struct dma_async_tx_descriptor *
cheshire_idma_prep_memcpy(struct dma_chan *chan, dma_addr_t dst,
			 dma_addr_t src, size_t len, unsigned long flags)
{
	struct cheshire_idma_desc *desc;

	if (!len)
		return NULL;

	desc = kzalloc(sizeof(*desc), GFP_NOWAIT);
	if (!desc)
		return NULL;

	desc->src = src;
	desc->dst = dst;
	desc->len = len;

	return vchan_tx_prep(to_virt_chan(chan), &desc->vd, flags);
}

static bool cheshire_idma_done(u32 done, u32 issued)
{
	/* The frontend's IDs are monotonically increasing modulo 2^32. */
	return (s32)(done - issued) >= 0;
}

static int cheshire_idma_run(struct cheshire_idma *idma,
			    struct cheshire_idma_desc *desc)
{
	u32 issued, done = 0;
	unsigned int poll;

	/*
	 * writeq matches Cheshire's own bare-metal DIF and fills each low/high
	 * register pair in one naturally aligned transaction.  The final read of
	 * NEXT_ID launches the transfer.
	 */
	writeq(desc->src, idma->base + CHESHIRE_IDMA_SRC_ADDR);
	writeq(desc->dst, idma->base + CHESHIRE_IDMA_DST_ADDR);
	writeq(desc->len, idma->base + CHESHIRE_IDMA_LENGTH);
	writel(0, idma->base + CHESHIRE_IDMA_CONF);
	issued = readl(idma->base + CHESHIRE_IDMA_NEXT_ID);
	if (!issued)
		return -EIO;

	WRITE_ONCE(submitted, READ_ONCE(submitted) + 1);
	for (poll = 0; poll < CHESHIRE_IDMA_MAX_POLLS; poll++) {
		done = readl(idma->base + CHESHIRE_IDMA_DONE_ID);
		if (cheshire_idma_done(done, issued)) {
			WRITE_ONCE(completed, READ_ONCE(completed) + 1);
			return 0;
		}
		cpu_relax();
	}

	WRITE_ONCE(timeouts, READ_ONCE(timeouts) + 1);
	dev_err(idma->ddev.dev,
		"transfer %u timed out (DONE_ID=%u, len=%zu)\n",
		issued, done, desc->len);
	return -ETIMEDOUT;
}

static void cheshire_idma_worker(struct work_struct *work)
{
	struct cheshire_idma *idma =
		container_of(work, struct cheshire_idma, work);
	struct virt_dma_desc *vd;
	unsigned long flags;

	for (;;) {
		struct cheshire_idma_desc *desc;
		int ret;

		spin_lock_irqsave(&idma->vc.lock, flags);
		vd = vchan_next_desc(&idma->vc);
		if (!vd) {
			spin_unlock_irqrestore(&idma->vc.lock, flags);
			return;
		}
		list_del(&vd->node);
		spin_unlock_irqrestore(&idma->vc.lock, flags);

		desc = to_cheshire_desc(vd);
		ret = cheshire_idma_run(idma, desc);
		if (ret)
			desc->vd.tx_result.result = DMA_TRANS_ABORTED;

		spin_lock_irqsave(&idma->vc.lock, flags);
		vchan_cookie_complete(&desc->vd);
		spin_unlock_irqrestore(&idma->vc.lock, flags);
	}
}

static void cheshire_idma_issue_pending(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);
	unsigned long flags;
	bool ready;

	spin_lock_irqsave(&idma->vc.lock, flags);
	ready = vchan_issue_pending(&idma->vc);
	spin_unlock_irqrestore(&idma->vc.lock, flags);

	if (ready)
		schedule_work(&idma->work);
}

static enum dma_status cheshire_idma_tx_status(struct dma_chan *chan,
					       dma_cookie_t cookie,
					       struct dma_tx_state *state)
{
	return dma_cookie_status(chan, cookie, state);
}

static int cheshire_idma_terminate_all(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);
	unsigned long flags;
	LIST_HEAD(head);

	/* The wrapper has no abort register; let an active bounded poll finish. */
	cancel_work_sync(&idma->work);

	spin_lock_irqsave(&idma->vc.lock, flags);
	vchan_get_all_descriptors(&idma->vc, &head);
	spin_unlock_irqrestore(&idma->vc.lock, flags);
	vchan_dma_desc_free_list(&idma->vc, &head);

	return 0;
}

static void cheshire_idma_synchronize(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);

	cancel_work_sync(&idma->work);
	vchan_synchronize(&idma->vc);
}

static void cheshire_idma_free_chan_resources(struct dma_chan *chan)
{
	cheshire_idma_terminate_all(chan);
	vchan_free_chan_resources(to_virt_chan(chan));
}

static struct dma_chan *
cheshire_idma_of_xlate(struct of_phandle_args *dma_spec,
			struct of_dma *ofdma)
{
	struct cheshire_idma *idma = ofdma->of_dma_data;

	if (dma_spec->args_count != 1 || dma_spec->args[0] != 0)
		return NULL;
	return dma_get_any_slave_channel(&idma->ddev);
}

static int cheshire_idma_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct cheshire_idma *idma;
	int ret;

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(48));
	if (ret)
		return dev_err_probe(dev, ret, "failed to set 48-bit DMA mask\n");

	idma = devm_kzalloc(dev, sizeof(*idma), GFP_KERNEL);
	if (!idma)
		return -ENOMEM;

	idma->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(idma->base))
		return PTR_ERR(idma->base);

	INIT_WORK(&idma->work, cheshire_idma_worker);
	INIT_LIST_HEAD(&idma->ddev.channels);
	idma->ddev.dev = dev;
	dma_cap_set(DMA_MEMCPY, idma->ddev.cap_mask);
	idma->ddev.directions = BIT(DMA_MEM_TO_MEM);
	idma->ddev.residue_granularity = DMA_RESIDUE_GRANULARITY_DESCRIPTOR;
	idma->ddev.device_free_chan_resources =
		cheshire_idma_free_chan_resources;
	idma->ddev.device_prep_dma_memcpy = cheshire_idma_prep_memcpy;
	idma->ddev.device_issue_pending = cheshire_idma_issue_pending;
	idma->ddev.device_tx_status = cheshire_idma_tx_status;
	idma->ddev.device_terminate_all = cheshire_idma_terminate_all;
	idma->ddev.device_synchronize = cheshire_idma_synchronize;

	idma->vc.desc_free = cheshire_idma_desc_free;
	vchan_init(&idma->vc, &idma->ddev);

	ret = dma_async_device_register(&idma->ddev);
	if (ret)
		goto err_vchan;

	ret = of_dma_controller_register(dev->of_node,
					 cheshire_idma_of_xlate, idma);
	if (ret)
		goto err_unregister;

	platform_set_drvdata(pdev, idma);
	dev_info(dev, "registered polling DMAengine channel\n");
	return 0;

err_unregister:
	dma_async_device_unregister(&idma->ddev);
err_vchan:
	list_del(&idma->vc.chan.device_node);
	tasklet_kill(&idma->vc.task);
	return ret;
}

static void cheshire_idma_remove(struct platform_device *pdev)
{
	struct cheshire_idma *idma = platform_get_drvdata(pdev);

	of_dma_controller_free(pdev->dev.of_node);
	dma_async_device_unregister(&idma->ddev);
	cancel_work_sync(&idma->work);
	tasklet_kill(&idma->vc.task);
	list_del(&idma->vc.chan.device_node);
}

static const struct of_device_id cheshire_idma_of_match[] = {
	{ .compatible = "pulp,cheshire-idma-v0" },
	{ }
};
MODULE_DEVICE_TABLE(of, cheshire_idma_of_match);

static struct platform_driver cheshire_idma_driver = {
	.probe = cheshire_idma_probe,
	.remove = cheshire_idma_remove,
	.driver = {
		.name = "cheshire-idma-investigation",
		.of_match_table = cheshire_idma_of_match,
	},
};
module_platform_driver(cheshire_idma_driver);

MODULE_DESCRIPTION("Investigation-only Cheshire iDMA DMAengine provider");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
