// SPDX-License-Identifier: GPL-2.0-only
/*
 * Investigation-only interrupt-driven DMAengine provider for Cheshire iDMA.
 *
 * This driver consumes a phase-only RTL ABI: reading DONE_ID acknowledges a
 * level completion interrupt and ABORT_STATUS requests a bounded active abort.
 * It is test scaffolding, not an upstream ABI proposal.
 */

#include <linux/completion.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_dma.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <asm/dma-noncoherent.h>

#include "virt-dma.h"

#define CHESHIRE_IDMA_CONF              0x000
#define CHESHIRE_IDMA_NEXT_ID           0x044
#define CHESHIRE_IDMA_DONE_ID           0x084
#define CHESHIRE_IDMA_DST_ADDR          0x0d0
#define CHESHIRE_IDMA_SRC_ADDR          0x0d8
#define CHESHIRE_IDMA_LENGTH            0x0e0
#define CHESHIRE_IDMA_ABORT_STATUS      0x100
#define CHESHIRE_IDMA_ABORT             BIT(0)

#define CHESHIRE_BUSERR_WRITE           0x00
#define CHESHIRE_BUSERR_READ            0x20
#define CHESHIRE_BUSERR_ADDR_LO         0x00
#define CHESHIRE_BUSERR_ADDR_HI         0x04
#define CHESHIRE_BUSERR_CODE            0x08
#define CHESHIRE_BUSERR_META            0x0c
#define CHESHIRE_BUSERR_CODE_MASK       GENMASK(1, 0)
#define CHESHIRE_BUSERR_FULL            BIT(31)
#define CHESHIRE_AXI_SLVERR             2
#define CHESHIRE_AXI_DECERR             3

#define CHESHIRE_ABORT_TIMEOUT_MS       1000

struct cheshire_idma_desc {
	struct virt_dma_desc vd;
	dma_addr_t src;
	dma_addr_t dst;
	size_t len;
	u32 issued_id;
};

struct cheshire_buserr {
	u64 addr;
	u32 code;
	u32 meta;
	bool present;
	bool valid;
};

struct cheshire_idma {
	struct dma_device ddev;
	struct virt_dma_chan vc;
	void __iomem *base;
	void __iomem *buserr;
	int completion_irq;
	int error_irq;
	struct cheshire_idma_desc *active;
	enum dmaengine_tx_result active_result;
	struct completion abort_done;
	bool terminating;
	bool abort_requested;
	bool quarantined;
};

static unsigned long submitted;
static unsigned long hw_completed;
static unsigned long completion_irqs;
static unsigned long error_irqs;
static unsigned long spurious_completion_irqs;
static unsigned long empty_error_irqs;
static unsigned long callbacks_queued;
static unsigned long success;
static unsigned long read_failed;
static unsigned long write_failed;
static unsigned long aborted;
static unsigned long abort_requests;
static unsigned long abort_terminals;
static unsigned long abort_timeouts;
static unsigned long queued_terminated;
static unsigned long descriptors_freed;
static unsigned long max_software_queue;
static unsigned long max_hardware_active;
static unsigned long slverr;
static unsigned long decerr;
static unsigned long buserr_records;
static unsigned long fifo_full_seen;
static unsigned long unexpected;
static unsigned long long expected_slverr_addr = 0x40000000ULL;
static unsigned long long expected_decerr_addr = 0x50000000ULL;

module_param(submitted, ulong, 0444);
module_param(hw_completed, ulong, 0444);
module_param(completion_irqs, ulong, 0444);
module_param(error_irqs, ulong, 0444);
module_param(spurious_completion_irqs, ulong, 0444);
module_param(empty_error_irqs, ulong, 0444);
module_param(callbacks_queued, ulong, 0444);
module_param(success, ulong, 0444);
module_param(read_failed, ulong, 0444);
module_param(write_failed, ulong, 0444);
module_param(aborted, ulong, 0444);
module_param(abort_requests, ulong, 0444);
module_param(abort_terminals, ulong, 0444);
module_param(abort_timeouts, ulong, 0444);
module_param(queued_terminated, ulong, 0444);
module_param(descriptors_freed, ulong, 0444);
module_param(max_software_queue, ulong, 0444);
module_param(max_hardware_active, ulong, 0444);
module_param(slverr, ulong, 0444);
module_param(decerr, ulong, 0444);
module_param(buserr_records, ulong, 0444);
module_param(fifo_full_seen, ulong, 0444);
module_param(unexpected, ulong, 0444);
module_param(expected_slverr_addr, ullong, 0444);
module_param(expected_decerr_addr, ullong, 0444);

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

static void cheshire_inc(unsigned long *counter)
{
	WRITE_ONCE(*counter, READ_ONCE(*counter) + 1);
}

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
	cheshire_inc(&descriptors_freed);
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
	desc->vd.tx_result.result = DMA_TRANS_NOERROR;
	desc->vd.tx_result.residue = len;
	return vchan_tx_prep(to_virt_chan(chan), &desc->vd, flags);
}

static bool cheshire_idma_done(u32 done, u32 issued)
{
	return (s32)(done - issued) >= 0;
}

/* ERR_CODE must be read last because that read pops one recorder entry. */
static struct cheshire_buserr
cheshire_buserr_read(struct cheshire_idma *idma, u32 bank)
{
	struct cheshire_buserr err;
	u32 lo, hi;

	lo = readl(idma->buserr + bank + CHESHIRE_BUSERR_ADDR_LO);
	hi = readl(idma->buserr + bank + CHESHIRE_BUSERR_ADDR_HI);
	err.meta = readl(idma->buserr + bank + CHESHIRE_BUSERR_META);
	err.code = readl(idma->buserr + bank + CHESHIRE_BUSERR_CODE);
	err.addr = ((u64)(hi & 0xffff) << 32) | lo;
	err.present = !!(err.code & CHESHIRE_BUSERR_CODE_MASK);
	err.valid = true;

	if (err.code & CHESHIRE_BUSERR_FULL) {
		cheshire_inc(&fifo_full_seen);
		err.valid = false;
	}
	if (err.present) {
		u32 resp = err.code & CHESHIRE_BUSERR_CODE_MASK;

		cheshire_inc(&buserr_records);
		if (resp == CHESHIRE_AXI_SLVERR) {
			cheshire_inc(&slverr);
			if (err.addr != expected_slverr_addr)
				err.valid = false;
		} else if (resp == CHESHIRE_AXI_DECERR) {
			cheshire_inc(&decerr);
			if (err.addr != expected_decerr_addr)
				err.valid = false;
		} else {
			err.valid = false;
		}
		dev_info(idma->ddev.dev,
			 "bus-error direction=%s address=%#llx code=%u meta=%u full=%u valid=%u\n",
			 bank == CHESHIRE_BUSERR_READ ? "read" : "write",
			 err.addr, resp, err.meta,
			 !!(err.code & CHESHIRE_BUSERR_FULL), err.valid);
	} else if (err.code) {
		err.valid = false;
	}
	if (!err.valid)
		cheshire_inc(&unexpected);
	return err;
}

/* Caller serializes this against both IRQ handlers with vc.lock. */
static bool cheshire_buserr_drain(struct cheshire_idma *idma)
{
	struct cheshire_buserr write_err;
	struct cheshire_buserr read_err;
	enum dmaengine_tx_result result = DMA_TRANS_NOERROR;
	bool present;

	write_err = cheshire_buserr_read(idma, CHESHIRE_BUSERR_WRITE);
	read_err = cheshire_buserr_read(idma, CHESHIRE_BUSERR_READ);
	present = write_err.present || read_err.present;
	if (!present)
		return false;

	if (!idma->active || !write_err.valid || !read_err.valid ||
	    (write_err.present && read_err.present)) {
		cheshire_inc(&unexpected);
		result = DMA_TRANS_ABORTED;
	} else if (read_err.present) {
		result = DMA_TRANS_READ_FAILED;
	} else {
		result = DMA_TRANS_WRITE_FAILED;
	}

	if (idma->active_result != DMA_TRANS_NOERROR) {
		cheshire_inc(&unexpected);
		idma->active_result = DMA_TRANS_ABORTED;
	} else {
		idma->active_result = result;
	}
	return true;
}

static unsigned int cheshire_queue_depth(struct cheshire_idma *idma)
{
	struct virt_dma_desc *vd;
	unsigned int depth = 0;

	list_for_each_entry(vd, &idma->vc.desc_issued, node)
		depth++;
	return depth;
}

/* vc.lock is held and local IRQs are disabled. */
static void cheshire_idma_start_next(struct cheshire_idma *idma)
{
	struct virt_dma_desc *vd;
	struct cheshire_idma_desc *desc;

	if (idma->active || idma->terminating || idma->quarantined)
		return;
	vd = vchan_next_desc(&idma->vc);
	if (!vd)
		return;
	list_del(&vd->node);
	desc = to_cheshire_desc(vd);
	idma->active = desc;
	idma->active_result = DMA_TRANS_NOERROR;
	reinit_completion(&idma->abort_done);

	writeq(desc->src, idma->base + CHESHIRE_IDMA_SRC_ADDR);
	writeq(desc->dst, idma->base + CHESHIRE_IDMA_DST_ADDR);
	writeq(desc->len, idma->base + CHESHIRE_IDMA_LENGTH);
	writel(0, idma->base + CHESHIRE_IDMA_CONF);
	desc->issued_id = readl(idma->base + CHESHIRE_IDMA_NEXT_ID);
	if (!desc->issued_id) {
		cheshire_inc(&unexpected);
		idma->quarantined = true;
		idma->active = NULL;
		desc->vd.tx_result.result = DMA_TRANS_ABORTED;
		desc->vd.tx_result.residue = desc->len;
		vchan_cookie_complete(&desc->vd);
		cheshire_inc(&callbacks_queued);
		return;
	}
	cheshire_inc(&submitted);
	if (max_hardware_active < 1)
		WRITE_ONCE(max_hardware_active, 1);
}

static irqreturn_t cheshire_idma_error_irq(int irq, void *data)
{
	struct cheshire_idma *idma = data;
	unsigned long flags;
	bool present;

	(void)irq;
	spin_lock_irqsave(&idma->vc.lock, flags);
	cheshire_inc(&error_irqs);
	present = cheshire_buserr_drain(idma);
	if (!present)
		cheshire_inc(&empty_error_irqs);
	spin_unlock_irqrestore(&idma->vc.lock, flags);
	return IRQ_HANDLED;
}

static irqreturn_t cheshire_idma_completion_irq(int irq, void *data)
{
	struct cheshire_idma *idma = data;
	struct cheshire_idma_desc *desc;
	enum dmaengine_tx_result result;
	unsigned long flags;
	u32 done;

	(void)irq;
	spin_lock_irqsave(&idma->vc.lock, flags);
	cheshire_inc(&completion_irqs);
	/* Reading DONE_ID acknowledges every completion visible at this point. */
	done = readl(idma->base + CHESHIRE_IDMA_DONE_ID);
	desc = idma->active;
	if (!desc) {
		cheshire_inc(&spurious_completion_irqs);
		spin_unlock_irqrestore(&idma->vc.lock, flags);
		return IRQ_HANDLED;
	}
	if (!cheshire_idma_done(done, desc->issued_id)) {
		cheshire_inc(&unexpected);
		spin_unlock_irqrestore(&idma->vc.lock, flags);
		return IRQ_HANDLED;
	}

	(void)cheshire_buserr_drain(idma);
	result = idma->active_result;
	idma->active = NULL;
	cheshire_inc(&hw_completed);

	if (idma->terminating || idma->abort_requested) {
		desc->vd.tx_result.result = DMA_TRANS_ABORTED;
		desc->vd.tx_result.residue = desc->len;
		vchan_terminate_vdesc(&desc->vd);
		cheshire_inc(&aborted);
		cheshire_inc(&abort_terminals);
		idma->terminating = false;
		idma->abort_requested = false;
		complete_all(&idma->abort_done);
		spin_unlock_irqrestore(&idma->vc.lock, flags);
		return IRQ_HANDLED;
	}

	desc->vd.tx_result.result = result;
	desc->vd.tx_result.residue = result == DMA_TRANS_NOERROR ? 0 : desc->len;
	switch (result) {
	case DMA_TRANS_NOERROR:
		cheshire_inc(&success);
		break;
	case DMA_TRANS_READ_FAILED:
		cheshire_inc(&read_failed);
		break;
	case DMA_TRANS_WRITE_FAILED:
		cheshire_inc(&write_failed);
		break;
	case DMA_TRANS_ABORTED:
		cheshire_inc(&aborted);
		break;
	}
	vchan_cookie_complete(&desc->vd);
	cheshire_inc(&callbacks_queued);
	cheshire_idma_start_next(idma);
	spin_unlock_irqrestore(&idma->vc.lock, flags);
	return IRQ_HANDLED;
}

static void cheshire_idma_issue_pending(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);
	unsigned long flags;
	unsigned int depth;

	spin_lock_irqsave(&idma->vc.lock, flags);
	if (vchan_issue_pending(&idma->vc)) {
		depth = cheshire_queue_depth(idma) + !!idma->active;
		if (depth > max_software_queue)
			WRITE_ONCE(max_software_queue, depth);
		cheshire_idma_start_next(idma);
	}
	spin_unlock_irqrestore(&idma->vc.lock, flags);
}

static struct cheshire_idma_desc *
cheshire_find_queued_desc(struct cheshire_idma *idma, dma_cookie_t cookie)
{
	struct cheshire_idma_desc *desc;
	struct virt_dma_desc *vd;

	if (idma->active && idma->active->vd.tx.cookie == cookie)
		return idma->active;
	list_for_each_entry(vd, &idma->vc.desc_submitted, node) {
		desc = to_cheshire_desc(vd);
		if (desc->vd.tx.cookie == cookie)
			return desc;
	}
	list_for_each_entry(vd, &idma->vc.desc_issued, node) {
		desc = to_cheshire_desc(vd);
		if (desc->vd.tx.cookie == cookie)
			return desc;
	}
	return NULL;
}

static enum dma_status cheshire_idma_tx_status(struct dma_chan *chan,
				       dma_cookie_t cookie,
				       struct dma_tx_state *state)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);
	struct cheshire_idma_desc *desc;
	enum dma_status status;
	unsigned long flags;

	status = dma_cookie_status(chan, cookie, state);
	if (!state || status == DMA_COMPLETE)
		return status;

	spin_lock_irqsave(&idma->vc.lock, flags);
	desc = cheshire_find_queued_desc(idma, cookie);
	if (desc)
		dma_set_residue(state, desc->len);
	spin_unlock_irqrestore(&idma->vc.lock, flags);
	return status;
}

static int cheshire_idma_terminate_all(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);
	struct virt_dma_desc *vd;
	unsigned long flags;
	unsigned long count = 0;
	LIST_HEAD(head);

	spin_lock_irqsave(&idma->vc.lock, flags);
	vchan_get_all_descriptors(&idma->vc, &head);
	list_for_each_entry(vd, &head, node)
		count++;
	if (idma->active && !idma->abort_requested) {
		idma->terminating = true;
		idma->abort_requested = true;
		cheshire_inc(&abort_requests);
		writel(CHESHIRE_IDMA_ABORT,
		       idma->base + CHESHIRE_IDMA_ABORT_STATUS);
	} else if (!idma->active) {
		idma->terminating = false;
		complete_all(&idma->abort_done);
	}
	spin_unlock_irqrestore(&idma->vc.lock, flags);

	WRITE_ONCE(queued_terminated, READ_ONCE(queued_terminated) + count);
	vchan_dma_desc_free_list(&idma->vc, &head);
	return 0;
}

static void cheshire_idma_synchronize(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);

	if (READ_ONCE(idma->terminating) &&
	    !wait_for_completion_timeout(&idma->abort_done,
					 msecs_to_jiffies(CHESHIRE_ABORT_TIMEOUT_MS))) {
		cheshire_inc(&abort_timeouts);
		WRITE_ONCE(idma->quarantined, true);
		dev_err(idma->ddev.dev, "active abort did not reach terminal response\n");
	}
	synchronize_irq(idma->completion_irq);
	synchronize_irq(idma->error_irq);
	vchan_synchronize(&idma->vc);
}

static void cheshire_idma_free_chan_resources(struct dma_chan *chan)
{
	struct cheshire_idma *idma = to_cheshire_idma(chan);

	cheshire_idma_terminate_all(chan);
	cheshire_idma_synchronize(chan);
	if (!READ_ONCE(idma->active))
		vchan_free_chan_resources(&idma->vc);
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
	idma->base = devm_platform_ioremap_resource_byname(pdev, "control");
	if (IS_ERR(idma->base))
		return PTR_ERR(idma->base);
	idma->buserr = devm_platform_ioremap_resource_byname(pdev, "bus-error");
	if (IS_ERR(idma->buserr))
		return PTR_ERR(idma->buserr);
	idma->completion_irq = platform_get_irq_byname(pdev, "completion");
	if (idma->completion_irq < 0)
		return idma->completion_irq;
	idma->error_irq = platform_get_irq_byname(pdev, "error");
	if (idma->error_irq < 0)
		return idma->error_irq;

	init_completion(&idma->abort_done);
	complete_all(&idma->abort_done);
	INIT_LIST_HEAD(&idma->ddev.channels);
	idma->ddev.dev = dev;
	dma_cap_set(DMA_MEMCPY, idma->ddev.cap_mask);
	idma->ddev.directions = BIT(DMA_MEM_TO_MEM);
	idma->ddev.residue_granularity = DMA_RESIDUE_GRANULARITY_DESCRIPTOR;
	idma->ddev.device_free_chan_resources = cheshire_idma_free_chan_resources;
	idma->ddev.device_prep_dma_memcpy = cheshire_idma_prep_memcpy;
	idma->ddev.device_issue_pending = cheshire_idma_issue_pending;
	idma->ddev.device_tx_status = cheshire_idma_tx_status;
	idma->ddev.device_terminate_all = cheshire_idma_terminate_all;
	idma->ddev.device_synchronize = cheshire_idma_synchronize;
	idma->vc.desc_free = cheshire_idma_desc_free;
	vchan_init(&idma->vc, &idma->ddev);

	ret = devm_request_irq(dev, idma->completion_irq,
			       cheshire_idma_completion_irq, 0,
			       "cheshire-idma-completion", idma);
	if (ret)
		goto err_vchan;
	ret = devm_request_irq(dev, idma->error_irq, cheshire_idma_error_irq, 0,
			       "cheshire-idma-error", idma);
	if (ret)
		goto err_vchan;

	/* Establish the reset acknowledgement before clients can submit work. */
	(void)readl(idma->base + CHESHIRE_IDMA_DONE_ID);
	ret = dma_async_device_register(&idma->ddev);
	if (ret)
		goto err_vchan;
	ret = of_dma_controller_register(dev->of_node,
					cheshire_idma_of_xlate, idma);
	if (ret)
		goto err_unregister;

	platform_set_drvdata(pdev, idma);
	dev_info(dev, "registered IRQ DMAengine channel: completion=%d error=%d\n",
		 idma->completion_irq, idma->error_irq);
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
	cheshire_idma_terminate_all(&idma->vc.chan);
	cheshire_idma_synchronize(&idma->vc.chan);
	tasklet_kill(&idma->vc.task);
	list_del(&idma->vc.chan.device_node);
}

static const struct of_device_id cheshire_idma_of_match[] = {
	{ .compatible = "pulp,cheshire-idma-v0.6.4-test" },
	{ }
};
MODULE_DEVICE_TABLE(of, cheshire_idma_of_match);

static struct platform_driver cheshire_idma_driver = {
	.probe = cheshire_idma_probe,
	.remove = cheshire_idma_remove,
	.driver = {
		.name = "cheshire-idma-irq-investigation",
		.of_match_table = cheshire_idma_of_match,
	},
};
module_platform_driver(cheshire_idma_driver);

MODULE_DESCRIPTION("Investigation-only IRQ-driven Cheshire iDMA provider");
MODULE_AUTHOR("OpenAI Codex investigation for Karl Mehltretter");
MODULE_LICENSE("GPL");
