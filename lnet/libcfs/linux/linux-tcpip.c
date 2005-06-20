/* -*- mode: c; c-basic-offset: 8; indent-tabs-mode: nil; -*-
 * vim:expandtab:shiftwidth=8:tabstop=8:
 *
 * Copyright (C) 2005 Cluster File Systems, Inc.
 *
 *   This file is part of Lustre, http://www.lustre.org.
 *
 *   Lustre is free software; you can redistribute it and/or
 *   modify it under the terms of version 2 of the GNU General Public
 *   License as published by the Free Software Foundation.
 *
 *   Lustre is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Lustre; if not, write to the Free Software
 *   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */
#define DEBUG_SUBSYSTEM S_PORTALS

#include <libcfs/kp30.h>
#include <libcfs/libcfs.h>

#include <linux/if.h>
#include <linux/in.h>

int
libcfs_ipif_query (char *name, int *up, __u32 *ip, __u32 *mask)
{
	mm_segment_t   oldmm = get_fs();
	struct ifreq   ifr;
        struct socket *sock;
        int            nob;
	int            rc;
	__u32          val;

	rc = sock_create(PF_INET, SOCK_STREAM, 0, &sock);
	if (rc != 0) {
		CERROR ("Can't create socket: %d\n", rc);
		return rc;
	}
	
	nob = strnlen(name, IFNAMSIZ);
	if (nob == IFNAMSIZ) {
		CERROR("Interface name %s too long\n", name);
		rc = -EINVAL;
		goto out;
	}
	
	CLASSERT (sizeof(ifr.ifr_name) >= IFNAMSIZ);

	strcpy(ifr.ifr_name, name);
	set_fs(KERNEL_DS);
	rc = sock->ops->ioctl(sock, SIOCGIFFLAGS, (unsigned long)&ifr);
	set_fs(oldmm);

	if (rc != 0) {
		CERROR("Can't get flags for interface %s\n", name);
		goto out;
	}

	if ((ifr.ifr_flags & IFF_UP) == 0) {
		CDEBUG(D_NET, "Interface %s down\n", name);
		*up = 0;
		*ip = *mask = 0;
		goto out;
	}

        *up = 1;

	strcpy(ifr.ifr_name, name);
	ifr.ifr_addr.sa_family = AF_INET;
	set_fs(KERNEL_DS);
	rc = sock->ops->ioctl(sock, SIOCGIFADDR, (unsigned long)&ifr);
	set_fs(oldmm);

	if (rc != 0) {
		CERROR("Can't get IP address for interface %s\n", name);
		goto out;
	}
	
	val = ((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr.s_addr;
	*ip = ntohl(val);

	strcpy(ifr.ifr_name, name);
	ifr.ifr_addr.sa_family = AF_INET;
	set_fs(KERNEL_DS);
	rc = sock->ops->ioctl(sock, SIOCGIFNETMASK, (unsigned long)&ifr);
	set_fs(oldmm);
	
	if (rc != 0) {
		CERROR("Can't get netmask for interface %s\n", name);
		goto out;
	}
	
	val = ((struct sockaddr_in *)&ifr.ifr_netmask)->sin_addr.s_addr;
	*mask = ntohl(val);

 out:
	sock_release(sock);
	return rc;
}

EXPORT_SYMBOL(libcfs_ipif_query);

int
libcfs_ipif_enumerate (char ***namesp)
{
	/* Allocate and fill in 'names', returning # interfaces/error */
        char           **names;
	int             toobig;
	int             nalloc;
	int             nfound;
	struct socket  *sock;
	struct ifreq   *ifr;
	struct ifconf   ifc;
	mm_segment_t    oldmm = get_fs();
	int             rc;
	int             nob;
	int             i;

	rc = sock_create (PF_INET, SOCK_STREAM, 0, &sock);
	if (rc != 0) {
		CERROR ("Can't create socket: %d\n", rc);
		return rc;
	}

	nalloc = 16;	/* first guess at max interfaces */
	toobig = 0;
	for (;;) {
		if (nalloc * sizeof(*ifr) > PAGE_SIZE) {
			toobig = 1;
			nalloc = PAGE_SIZE/sizeof(*ifr);
			CWARN("Too many interfaces: only enumerating first %d\n",
			      nalloc);
		}

		PORTAL_ALLOC(ifr, nalloc * sizeof(*ifr));
		if (ifr == NULL) {
			CERROR ("ENOMEM enumerating up to %d interfaces\n", nalloc);
			rc = -ENOMEM;
			goto out0;
		}
		
		ifc.ifc_buf = (char *)ifr;
		ifc.ifc_len = nalloc * sizeof(*ifr);
		
		set_fs(KERNEL_DS);
		rc = sock->ops->ioctl(sock, SIOCGIFCONF, (unsigned long)&ifc);
		set_fs(oldmm);

		if (rc < 0) {
			CERROR ("Error %d enumerating interfaces\n", rc);
			goto out1;
		}
		
		LASSERT (rc == 0);

		nfound = ifc.ifc_len/sizeof(*ifr);
		LASSERT (nfound <= nalloc);

		if (nfound < nalloc || toobig)
			break;

                PORTAL_FREE(ifr, nalloc * sizeof(*ifr));
		nalloc *= 2;
	}

        if (nfound == 0)
                goto out1;

        PORTAL_ALLOC(names, nfound * sizeof(*names));
        if (names == NULL) {
                rc = -ENOMEM;
                goto out1;
        }
        /* NULL out all names[i] */
        memset (names, 0, nfound * sizeof(*names));
                
	for (i = 0; i < nfound; i++) {

		nob = strnlen (ifr[i].ifr_name, IFNAMSIZ);
		if (nob == IFNAMSIZ) {
			/* no space for terminating NULL */
			CERROR("interface name %.*s too long (%d max)\n", 
			       nob, ifr[i].ifr_name, IFNAMSIZ);
			rc = -ENAMETOOLONG;
                        goto out2;
		}

                PORTAL_ALLOC(names[i], IFNAMSIZ);
                if (names[i] == NULL) {
                        rc = -ENOMEM;
                        goto out2;
                }

		memcpy(names[i], ifr[i].ifr_name, nob);
		names[i][nob] = 0;
	}

        *namesp = names;
	rc = nfound;
        
 out2:
        if (rc < 0)
                libcfs_ipif_free_enumeration(names, nfound);
 out1:
	PORTAL_FREE(ifr, nalloc * sizeof(*ifr));
 out0:
	sock_release(sock);
	return rc;
}

EXPORT_SYMBOL(libcfs_ipif_enumerate);

void
libcfs_ipif_free_enumeration (char **names, int n)
{
        int      i;

        LASSERT (n > 0);

        for (i = 0; i < n && names[i] != NULL; i++)
                PORTAL_FREE(names[i], IFNAMSIZ);

        PORTAL_FREE(names, n * sizeof(*names));
}

EXPORT_SYMBOL(libcfs_ipif_free_enumeration);

int
libcfs_sock_write (struct socket *sock, void *buffer, int nob, int timeout)
{
        int            rc;
        mm_segment_t   oldmm = get_fs();
	long           ticks = timeout * HZ;
	unsigned long  then;
	struct timeval tv;
	
	LASSERT (nob > 0);
	/* Caller may pass a zero timeout if she thinks the socket buffer is
	 * empty enough to take the whole message immediately */

        for (;;) {
                struct iovec  iov = {
                        .iov_base = buffer,
                        .iov_len  = nob
                };
                struct msghdr msg = {
                        .msg_name       = NULL,
                        .msg_namelen    = 0,
                        .msg_iov        = &iov,
                        .msg_iovlen     = 1,
                        .msg_control    = NULL,
                        .msg_controllen = 0,
                        .msg_flags      = (timeout == 0) ? MSG_DONTWAIT : 0
                };

		if (timeout != 0) {
			/* Set send timeout to remaining time */
			tv = (struct timeval) {
				.tv_sec = ticks / HZ,
				.tv_usec = ((ticks % HZ) * 1000000) / HZ
			};
			set_fs(KERNEL_DS);
			rc = sock_setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO,
					     (char *)&tv, sizeof(tv));
			set_fs(oldmm);
			if (rc != 0) {
				CERROR("Can't set socket send timeout "
				       "%ld.%06d: %d\n", 
                                       (long)tv.tv_sec, (int)tv.tv_usec, rc);
				return rc;
			}
		}

                set_fs (KERNEL_DS);
                then = jiffies;
                rc = sock_sendmsg (sock, &msg, iov.iov_len);
                ticks -= then - jiffies;
                set_fs (oldmm);

		if (rc == nob)
			return 0;

                if (rc < 0)
                        return rc;

                if (rc == 0) {
                        CERROR ("Unexpected zero rc\n");
                        return (-ECONNABORTED);
                }

		if (ticks <= 0)
			return -EAGAIN;
		
                buffer = ((char *)buffer) + rc;
                nob -= rc;
        }

        return (0);
}

EXPORT_SYMBOL(libcfs_sock_write);

int
libcfs_sock_read (struct socket *sock, void *buffer, int nob, int timeout)
{
        int            rc;
        mm_segment_t   oldmm = get_fs();
        long           ticks = timeout * HZ;
        unsigned long  then;
        struct timeval tv;

        LASSERT (nob > 0);
        LASSERT (ticks > 0);

        for (;;) {
                struct iovec  iov = {
                        .iov_base = buffer,
                        .iov_len  = nob
                };
                struct msghdr msg = {
                        .msg_name       = NULL,
                        .msg_namelen    = 0,
                        .msg_iov        = &iov,
                        .msg_iovlen     = 1,
                        .msg_control    = NULL,
                        .msg_controllen = 0,
                        .msg_flags      = 0
                };

                /* Set receive timeout to remaining time */
                tv = (struct timeval) {
                        .tv_sec = ticks / HZ,
                        .tv_usec = ((ticks % HZ) * 1000000) / HZ
                };
                set_fs(KERNEL_DS);
                rc = sock_setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                                     (char *)&tv, sizeof(tv));
                set_fs(oldmm);
                if (rc != 0) {
                        CERROR("Can't set socket recv timeout %ld.%06d: %d\n",
                               (long)tv.tv_sec, (int)tv.tv_usec, rc);
                        return rc;
                }

                set_fs(KERNEL_DS);
                then = jiffies;
                rc = sock_recvmsg(sock, &msg, iov.iov_len, 0);
                ticks -= jiffies - then;
                set_fs(oldmm);

                if (rc < 0)
                        return rc;

                if (rc == 0)
                        return -ECONNABORTED;

                buffer = ((char *)buffer) + rc;
                nob -= rc;

                if (nob == 0)
                        return 0;

                if (ticks <= 0)
                        return -ETIMEDOUT;
        }
}

EXPORT_SYMBOL(libcfs_sock_read);

static int
libcfs_sock_create (struct socket **sockp, int *fatal, 
                    __u32 local_ip, int local_port)
{
        struct sockaddr_in  locaddr;
        struct socket      *sock;
        int                 rc;
        int                 option;
        mm_segment_t        oldmm = get_fs();

        /* All errors are fatal except bind failure if the port is in use */
	*fatal = 1;

        rc = sock_create (PF_INET, SOCK_STREAM, 0, &sock);
        *sockp = sock;
        if (rc != 0) {
                CERROR ("Can't create socket: %d\n", rc);
                return (rc);
        }

        set_fs (KERNEL_DS);
        option = 1;
        rc = sock_setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,
                             (char *)&option, sizeof (option));
        set_fs (oldmm);
        if (rc != 0) {
                CERROR("Can't set SO_REUSEADDR for socket: %d\n", rc);
                goto failed;
        }

        /* can't specify a local port without a local IP */
        LASSERT (local_ip == 0 || local_port != 0);

        if (local_ip != 0 || local_port != 0) {
                memset(&locaddr, 0, sizeof(locaddr));
                locaddr.sin_family = AF_INET;
                locaddr.sin_port = htons(local_port);
                locaddr.sin_addr.s_addr = (local_ip == 0) ? 
                                          INADDR_ANY : htonl(local_ip);
                
                rc = sock->ops->bind(sock, (struct sockaddr *)&locaddr, 
                                     sizeof(locaddr));
                if (rc == -EADDRINUSE) {
                        CDEBUG(D_NET, "Port %d already in use\n", local_port);
                        *fatal = 0;
                        goto failed;
                }
                if (rc != 0) {
                        CERROR("Error trying to bind to port %d: %d\n",
                               local_port, rc);
                        goto failed;
                }
        }
        
	return 0;

 failed:
        sock_release(sock);
        return rc;
}

int
libcfs_sock_setbuf (struct socket *sock, int txbufsize, int rxbufsize)
{
        mm_segment_t        oldmm = get_fs();
        int                 option;
        int                 rc;

        if (txbufsize != 0) {
                option = txbufsize;
                set_fs (KERNEL_DS);
                rc = sock_setsockopt(sock, SOL_SOCKET, SO_SNDBUF,
                                     (char *)&option, sizeof (option));
                set_fs (oldmm);
                if (rc != 0) {
                        CERROR ("Can't set send buffer %d: %d\n", 
                                option, rc);
                        return (rc);
                }
        }
        
        if (rxbufsize != 0) {
                option = rxbufsize;
                set_fs (KERNEL_DS);
                rc = sock_setsockopt (sock, SOL_SOCKET, SO_RCVBUF,
                                      (char *)&option, sizeof (option));
                set_fs (oldmm);
                if (rc != 0) {
                        CERROR ("Can't set receive buffer %d: %d\n", 
                                option, rc);
                        return (rc);
                }
        }
        
        return 0;
}

EXPORT_SYMBOL(libcfs_sock_setbuf);

int
libcfs_sock_getaddr (struct socket *sock, int remote, __u32 *ip, int *port)
{
        struct sockaddr_in sin;
        int                len = sizeof (sin);
        int                rc;

        rc = sock->ops->getname (sock, (struct sockaddr *)&sin, &len,
                                 remote ? 2 : 0);
        if (rc != 0) {
                CERROR ("Error %d getting sock %s IP/port\n",
                        rc, remote ? "peer" : "local");
                return rc;
        }

        if (ip != NULL)
                *ip = ntohl (sin.sin_addr.s_addr);

        if (port != NULL)
                *port = ntohs (sin.sin_port);

        return 0;
}

EXPORT_SYMBOL(libcfs_sock_getaddr);

int
libcfs_sock_getbuf (struct socket *sock, int *txbufsize, int *rxbufsize)
{
        mm_segment_t        oldmm = get_fs();
        int                 option;
        int                 optlen;
        int                 rc;

        if (txbufsize != NULL) {
                optlen = sizeof(option);
                set_fs (KERNEL_DS);
                rc = sock_getsockopt(sock, SOL_SOCKET, SO_SNDBUF,
                                     (char *)&option, &optlen);
                set_fs (oldmm);
                if (rc != 0) {
                        CERROR ("Can't get send buffer size: %d\n", rc);
                        return (rc);
                }
                *txbufsize = option;
        }
        
        if (rxbufsize != NULL) {
                optlen = sizeof(option);
                set_fs (KERNEL_DS);
                rc = sock_getsockopt (sock, SOL_SOCKET, SO_RCVBUF,
                                      (char *)&option, &optlen);
                set_fs (oldmm);
                if (rc != 0) {
                        CERROR ("Can't get receive buffer size: %d\n", rc);
                        return (rc);
                }
                *rxbufsize = option;
        }
        
        return 0;
}

EXPORT_SYMBOL(libcfs_sock_getbuf);

int
libcfs_sock_listen (struct socket **sockp, 
                    __u32 local_ip, int local_port, int backlog)
{
        int      fatal;
	int      rc;

        rc = libcfs_sock_create(sockp, &fatal, local_ip, local_port);
        if (rc != 0) {
                if (!fatal)
                        CERROR("Can't create socket: port %d already in use\n",
                               local_port);
                return rc;
        }
        
	rc = (*sockp)->ops->listen(*sockp, backlog);
	if (rc == 0)
		return 0;
	
	CERROR("Can't set listen backlog %d: %d\n", backlog, rc);
	sock_release(*sockp);
	return rc;
}

EXPORT_SYMBOL(libcfs_sock_listen);

int
libcfs_sock_accept (struct socket **newsockp, struct socket *sock)
{
	wait_queue_t   wait;
	struct socket *newsock;
	int            rc;

	init_waitqueue_entry(&wait, current);

	newsock = sock_alloc();
	if (newsock == NULL) {
		CERROR("Can't allocate socket\n");
		return -ENOMEM;
	}

	/* XXX this should add a ref to sock->ops->owner, if
	 * TCP could be a module */
	newsock->type = sock->type;
	newsock->ops = sock->ops;

	set_current_state(TASK_INTERRUPTIBLE);
	add_wait_queue(sock->sk->sk_sleep, &wait);
	
	rc = sock->ops->accept(sock, newsock, O_NONBLOCK);
	if (rc == -EAGAIN) {
		/* Nothing ready, so wait for activity */
		schedule();
		rc = sock->ops->accept(sock, newsock, O_NONBLOCK);
	}
	
	remove_wait_queue(sock->sk->sk_sleep, &wait);
	set_current_state(TASK_RUNNING);

	if (rc != 0)
		goto failed;

	*newsockp = newsock;
	return 0;

 failed:
	sock_release(newsock);
	return rc;
}

EXPORT_SYMBOL(libcfs_sock_accept);

void
libcfs_sock_abort_accept (struct socket *sock)
{
	wake_up_all(sock->sk->sk_sleep);
}

EXPORT_SYMBOL(libcfs_sock_abort_accept);

int
libcfs_sock_connect (struct socket **sockp, int *fatal,
                     __u32 local_ip, int local_port,
                     __u32 peer_ip, int peer_port)
{
        struct sockaddr_in  srvaddr;
        int                 rc;

	rc = libcfs_sock_create(sockp, fatal, local_ip, local_port);
	if (rc != 0)
		return rc;

        memset (&srvaddr, 0, sizeof (srvaddr));
        srvaddr.sin_family = AF_INET;
        srvaddr.sin_port = htons(peer_port);
        srvaddr.sin_addr.s_addr = htonl(peer_ip);

        rc = (*sockp)->ops->connect(*sockp,
				    (struct sockaddr *)&srvaddr, sizeof(srvaddr),
				    0);
        if (rc == 0)
                return 0;

        /* EADDRNOTAVAIL probably means we're already connected to the same
         * peer/port on the same local port on a differently typed
         * connection.  Let our caller retry with a different local
         * port... */
        *fatal = !(rc == -EADDRNOTAVAIL);

        CDEBUG(*fatal ? D_ERROR : D_NET,
               "Error %d connecting %u.%u.%u.%u/%d -> %u.%u.%u.%u/%d\n", rc,
               HIPQUAD(local_ip), local_port, HIPQUAD(peer_ip), peer_port);

 failed:
	sock_release(*sockp);
        return rc;
}

EXPORT_SYMBOL(libcfs_sock_connect);

void
libcfs_sock_release (struct socket *sock)
{
	sock_release(sock);
}

EXPORT_SYMBOL(libcfs_sock_release);
