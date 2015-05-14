# AIX scripts

This is a small collection of AIX related scripts. YMMV in terms of usage.

* **run_aix_system_backup** : script provides a centralized backup & recovery method involving a NIM master or any other available NFS server. Features:
 * Support for AIX & VIOS hosts.
 * Use of specific VIOS backup tools (iosbackup, viosbr …).
 * Support for local, NFS based backups (NIM or other targets). Don’t use local unless required since a local backup may be totally useless for recovery!
 * Support for 2 generations of backups.
 * Saving of LPAR profile data (IVM only).
 * Simple error alerting via mail.
For more documentation, read http://www.kudos.be/Projects/Comprehensive_AIX_system_backup_script_%28mksysb,_iosbackup%29.html


