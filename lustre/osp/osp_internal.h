/*
 * GPL HEADER START
 *
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 only,
 * as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License version 2 for more details (a copy is included
 * in the LICENSE file that accompanied this code).
 *
 * You should have received a copy of the GNU General Public License
 * version 2 along with this program; If not, see
 * http://www.sun.com/software/products/lustre/docs/GPLv2.pdf
 *
 * Please contact Sun Microsystems, Inc., 4150 Network Circle, Santa Clara,
 * CA 95054 USA or visit www.sun.com if you need additional information or
 * have any questions.
 *
 * GPL HEADER END
 */
/*
 * Copyright (c) 2007, 2010, Oracle and/or its affiliates. All rights reserved.
 * Use is subject to license terms.
 *
 * Copyright (c) 2012, Intel Corporation.
 */
/*
 * This file is part of Lustre, http://www.lustre.org/
 * Lustre is a trademark of Sun Microsystems, Inc.
 *
 * lustre/osp/osp_internal.h
 *
 * Author: Alex Zhuravlev <alexey.zhuravlev@intel.com>
 */

#ifndef _OSP_INTERNAL_H
#define _OSP_INTERNAL_H

#include <obd.h>
#include <obd_class.h>
#include <dt_object.h>
#include <lustre_fid.h>

/*
 * Infrastructure to support tracking of last committed llog record
 */
struct osp_id_tracker {
	spinlock_t		 otr_lock;
	__u32			 otr_next_id;
	__u32			 otr_committed_id;
	/* callback is register once per diskfs -- that's the whole point */
	struct dt_txn_callback	 otr_tx_cb;
	/* single node can run many clusters */
	cfs_list_t		 otr_wakeup_list;
	cfs_list_t		 otr_list;
	/* underlying shared device */
	struct dt_device	*otr_dev;
	/* how many users of this tracker */
	cfs_atomic_t		 otr_refcount;
};

struct osp_device {
	struct dt_device		 opd_dt_dev;
	/* corresponded OST index */
	int				 opd_index;
	/* device used to store persistent state (llogs, last ids) */
	struct obd_export		*opd_storage_exp;
	struct dt_device		*opd_storage;
	struct dt_object		*opd_last_used_file;

	/* stored persistently in LE format, updated directly to/from disk
	 * and required le64_to_cpu() conversion before use.
	 * Protected by opd_pre_lock */
	volatile obd_id			 opd_last_used_id;

	obd_id				 opd_gap_start;
	int				 opd_gap_count;
	/* connection to OST */
	struct obd_device		*opd_obd;
	struct obd_export		*opd_exp;
	struct obd_uuid			 opd_cluuid;
	struct obd_connect_data		*opd_connect_data;
	int				 opd_connects;
	cfs_proc_dir_entry_t		*opd_proc_entry;
	struct lprocfs_stats		*opd_stats;
	/* connection status. */
	int				 opd_new_connection;
	int				 opd_got_disconnected;
	int				 opd_imp_connected;
	int				 opd_imp_active;
	int				 opd_imp_seen_connected:1;

	/* whether local recovery is completed:
	 * reported via ->ldo_recovery_complete() */
	int				 opd_recovery_completed;

	/*
	 * Precreation pool
	 */
	spinlock_t			 opd_pre_lock;
	/* last id assigned in creation */
	__u64				 opd_pre_used_id;
	/* last created id OST reported, next-created - available id's */
	__u64				 opd_pre_last_created;
	/* how many ids are reserved in declare, we shouldn't block in create */
	__u64				 opd_pre_reserved;
	/* dedicate precreate thread */
	struct ptlrpc_thread		 opd_pre_thread;
	/* thread waits for signals about pool going empty */
	cfs_waitq_t			 opd_pre_waitq;
	/* consumers (who needs new ids) wait here */
	cfs_waitq_t			 opd_pre_user_waitq;
	/* current precreation status: working, failed, stopping? */
	int				 opd_pre_status;
	/* how many to precreate next time */
	int				 opd_pre_grow_count;
	int				 opd_pre_min_grow_count;
	int				 opd_pre_max_grow_count;
	/* whether to grow precreation window next time or not */
	int				 opd_pre_grow_slow;
	/* cleaning up orphans or recreating missing objects */
	int				 opd_pre_recovering;

	/*
	 * OST synchronization
	 */
	spinlock_t			 opd_syn_lock;
	/* unique generation, to recognize start of new records in the llog */
	struct llog_gen			 opd_syn_generation;
	/* number of changes to sync, used to wake up sync thread */
	unsigned long			 opd_syn_changes;
	/* processing of changes from previous mount is done? */
	int				 opd_syn_prev_done;
	/* found records */
	struct ptlrpc_thread		 opd_syn_thread;
	cfs_waitq_t			 opd_syn_waitq;
	/* list of remotely committed rpc */
	cfs_list_t			 opd_syn_committed_there;
	/* number of changes being under sync */
	int				 opd_syn_sync_in_progress;
	/* number of RPCs in flight - flow control */
	int				 opd_syn_rpc_in_flight;
	int				 opd_syn_max_rpc_in_flight;
	/* number of RPC in processing (including non-committed by OST) */
	int				 opd_syn_rpc_in_progress;
	int				 opd_syn_max_rpc_in_progress;
	/* osd api's commit cb control structure */
	struct dt_txn_callback		 opd_syn_txn_cb;
	/* last used change number -- semantically similar to transno */
	unsigned long			 opd_syn_last_used_id;
	/* last committed change number -- semantically similar to
	 * last_committed */
	unsigned long			 opd_syn_last_committed_id;
	/* last processed (taken from llog) id */
	unsigned long			 opd_syn_last_processed_id;
	struct osp_id_tracker		*opd_syn_tracker;
	cfs_list_t			 opd_syn_ontrack;

	/*
	 * statfs related fields: OSP maintains it on its own
	 */
	struct obd_statfs		 opd_statfs;
	cfs_time_t			 opd_statfs_fresh_till;
	cfs_timer_t			 opd_statfs_timer;
	int				 opd_statfs_update_in_progress;
	/* how often to update statfs data */
	int				 opd_statfs_maxage;

	cfs_proc_dir_entry_t		*opd_symlink;
};

extern cfs_mem_cache_t *osp_object_kmem;

/* this is a top object */
struct osp_object {
	struct lu_object_header	 opo_header;
	struct dt_object	 opo_obj;
	int			 opo_reserved:1,
				 opo_new:1;
};

extern struct lu_object_operations osp_lu_obj_ops;
extern const struct dt_device_operations osp_dt_ops;

struct osp_thread_info {
	struct lu_buf		 osi_lb;
	struct lu_fid		 osi_fid;
	struct lu_attr		 osi_attr;
	struct ost_id		 osi_oi;
	obd_id			 osi_id;
	loff_t			 osi_off;
	union {
		struct llog_rec_hdr		osi_hdr;
		struct llog_unlink64_rec	osi_unlink;
		struct llog_setattr64_rec	osi_setattr;
		struct llog_gen_rec		osi_gen;
	};
	struct llog_cookie	 osi_cookie;
	struct llog_catid	 osi_cid;
};

static inline void osp_objid_buf_prep(struct osp_thread_info *osi,
				      struct osp_device *d, int index)
{
	osi->osi_lb.lb_buf = (void *)&d->opd_last_used_id;
	osi->osi_lb.lb_len = sizeof(d->opd_last_used_id);
	osi->osi_off = sizeof(d->opd_last_used_id) * index;
}

extern struct lu_context_key osp_thread_key;

static inline struct osp_thread_info *osp_env_info(const struct lu_env *env)
{
	struct osp_thread_info *info;

	info = lu_context_key_get(&env->le_ctx, &osp_thread_key);
	if (info == NULL) {
		lu_env_refill((struct lu_env *)env);
		info = lu_context_key_get(&env->le_ctx, &osp_thread_key);
	}
	LASSERT(info);
	return info;
}

struct osp_txn_info {
	__u32   oti_current_id;
};

extern struct lu_context_key osp_txn_key;

static inline struct osp_txn_info *osp_txn_info(struct lu_context *ctx)
{
	struct osp_txn_info *info;

	info = lu_context_key_get(ctx, &osp_txn_key);
	return info;
}

extern const struct lu_device_operations osp_lu_ops;

static inline int lu_device_is_osp(struct lu_device *d)
{
	return ergo(d != NULL && d->ld_ops != NULL, d->ld_ops == &osp_lu_ops);
}

static inline struct osp_device *lu2osp_dev(struct lu_device *d)
{
	LASSERT(lu_device_is_osp(d));
	return container_of0(d, struct osp_device, opd_dt_dev.dd_lu_dev);
}

static inline struct lu_device *osp2lu_dev(struct osp_device *d)
{
	return &d->opd_dt_dev.dd_lu_dev;
}

static inline struct osp_device *dt2osp_dev(struct dt_device *d)
{
	LASSERT(lu_device_is_osp(&d->dd_lu_dev));
	return container_of0(d, struct osp_device, opd_dt_dev);
}

static inline struct osp_object *lu2osp_obj(struct lu_object *o)
{
	LASSERT(ergo(o != NULL, lu_device_is_osp(o->lo_dev)));
	return container_of0(o, struct osp_object, opo_obj.do_lu);
}

static inline struct lu_object *osp2lu_obj(struct osp_object *obj)
{
	return &obj->opo_obj.do_lu;
}

static inline struct osp_object *osp_obj(const struct lu_object *o)
{
	LASSERT(lu_device_is_osp(o->lo_dev));
	return container_of0(o, struct osp_object, opo_obj.do_lu);
}

static inline struct osp_object *dt2osp_obj(const struct dt_object *d)
{
	return osp_obj(&d->do_lu);
}

static inline struct dt_object *osp_object_child(struct osp_object *o)
{
	return container_of0(lu_object_next(osp2lu_obj(o)),
                             struct dt_object, do_lu);
}

/* osp_dev.c */
void osp_update_last_id(struct osp_device *d, obd_id objid);

/* osp_precreate.c */
int osp_init_precreate(struct osp_device *d);
int osp_precreate_reserve(const struct lu_env *env, struct osp_device *d);
__u64 osp_precreate_get_id(struct osp_device *d);
void osp_precreate_fini(struct osp_device *d);
int osp_object_truncate(const struct lu_env *env, struct dt_object *dt, __u64);
void osp_pre_update_status(struct osp_device *d, int rc);
void osp_statfs_need_now(struct osp_device *d);

/* lproc_osp.c */
void lprocfs_osp_init_vars(struct lprocfs_static_vars *lvars);
void osp_lprocfs_init(struct osp_device *osp);

/* osp_sync.c */
int osp_sync_declare_add(const struct lu_env *env, struct osp_object *o,
			 llog_op_type type, struct thandle *th);
int osp_sync_add(const struct lu_env *env, struct osp_object *o,
		 llog_op_type type, struct thandle *th,
		 const struct lu_attr *attr);
int osp_sync_init(const struct lu_env *env, struct osp_device *d);
int osp_sync_fini(struct osp_device *d);
void __osp_sync_check_for_work(struct osp_device *d);

/* osp_ost.c */
int osp_init_for_ost(const struct lu_env *env, struct osp_device *m,
		     struct lu_device_type *ldt, struct lustre_cfg *cfg);
int osp_disconnect(struct osp_device *d);
int osp_fini_for_ost(struct osp_device *osp);

#endif
