#!/bin/env ksh
#******************************************************************************
# @(#) run_aix_system_backup.sh
#******************************************************************************
# @(#) Copyright (C) 2013 by KUDOS BVBA <info@kudos.be>.  All rights reserved.
#
# This program is a free software; you can redistribute it and/or modify
# it under the same terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details
#******************************************************************************
# @(#) MAIN: control_pkg_db.sh
# DOES: performs an mksysb, backupios, viosbr backup of an AIX/VIOS host to a 
#       local, NIM-based or NFS location; optionally creates a snap of the host
# EXPECTS: (see --help for more options)
# REQUIRES: check_lock_dir_(), check_params(), check_platform(), check_run_user(),
#           die(), display_usage(), do_cleanup(), log(), send_alert(), warn()
#           For other pre-requisites see the documentation in display_usage()
#******************************************************************************

#******************************************************************************
# DATA structures
#******************************************************************************

# ------------------------- CONFIGURATION starts here -------------------------
# define the V.R.F (version/release/fix)
AIX_VRF="1.0.0"
# specify the UNIX user that needs to be used for executing the script
EXEC_USER="root"
# default list of recipients receiving error/warning e-mails
TO_MSG="foo@bar.com"
# location of log directory (default), see --log-dir)
LOG_DIR="/var/log"
# location of temporary working storage
TMP_DIR="/var/tmp"
# ------------------------- CONFIGURATION ends here ---------------------------
# miscelleaneous
PATH=${PATH}:/usr/bin:/usr/local/bin
SCRIPT_NAME=$(basename $0)
SCRIPT_DIR=$(dirname $0)
HOST_NAME=$(hostname)
RC_VIOSBR=0
RC_BACKUPIOS=0
RC_MKSYSB=0
RC_SNAP=0
RC_NFS=0
VIOS_VERSION=""
# command-line parameters
ARG_IS_IVM=0            # whether the VIOS host is using IVM for LPAR management
ARG_IS_VIOS=0           # whether the host is a VIOS, not a VIOS by default
ARG_LOG_DIR=""          # location of the log directory (~root, thaler etc)
ARG_NFS_DIR=""          # location of the save directory on the NFS server
ARG_NIM_DIR=""          # location of the save directory on the NIM master
ARG_LOCAL_DIR=""        # location of the local save directory
ARG_MAKE_SNAP=0         # make AIX 'snap' is off by default
ARG_SEND_ALERT=0        # sending mail is off by default
ARG_USE_NFS=0           # use NFS mount from random host (via AutoFS) is off by default
ARG_USE_NIM=0           # use NFS mount from NIM (via AutoFS) is off by default
ARG_LOG=1               # logging is on by default
ARG_VERBOSE=1           # STDOUT/STDERR is on by default


#******************************************************************************
# FUNCTION routines
#******************************************************************************

# -----------------------------------------------------------------------------
function check_lock_dir
{
LOCK_DIR="${TMP_DIR}/.${SCRIPT_NAME}.lock"
mkdir ${LOCK_DIR} >/dev/null || {
    print -u2 "ERROR: unable to acquire lock ${LOCK_DIR}"
    ARG_VERBOSE=0 warn "unable to acquire lock ${LOCK_DIR}"
    if [[ -f ${LOCK_DIR}/.pid ]] 
    then
        LOCK_PID="$(cat ${LOCK_DIR}/.pid)"
        print -u2 "ERROR: active MKSYSB running on PID: ${LOCK_PID}"
        ARG_VERBOSE=0 warn "active MKSYSB running on PID: ${LOCK_PID}. Exiting!"
    fi
    exit 1
}
print $$ >${LOCK_DIR}/.pid

return 0
}

# -----------------------------------------------------------------------------
function check_params
{
# --is-ivm
if (( ARG_IS_VIOS == 0 && ARG_IS_IVM != 0 ))
then
    print -u2 "ERROR: you cannot use '--is-ivm' without the '--is-vios' parameter"
    exit 1
fi
# --is-vios
if (( ARG_IS_VIOS != 0 ))
then
    VIOS_VERSION="$(cat /usr/ios/cli/ios.level 2>/dev/null)"
    if [[ -z "${VIOS_VERSION}" ]]
    then
        print -u2 "ERROR: host is a not a VIO server, bailing out"
        exit 1
    fi
fi
# --local-dir
if (( ARG_USE_NIM == 0 && ARG_USE_NFS == 0 ))
then
    if [[ -z "${ARG_LOCAL_DIR}" ]]
    then
        print -u2 "ERROR: you must specify a value for parameter '--local-dir'"
        exit 1
    else
        # create if missing
        [[ -d "${ARG_LOCAL_DIR}" ]] || mkdir -p "${ARG_LOCAL_DIR}" >/dev/null    
        if [ \( ! -d "${ARG_LOCAL_DIR}" \) -o \( ! -w "${ARG_LOCAL_DIR}" \) ]
        then
            print -u2 "ERROR: unable to create/write to the target directory at ${ARG_LOCAL_DIR}"
            exit 1    
        fi    
    fi
fi
# --use-nfs/--nfs-dir
if (( ARG_USE_NFS != 0 ))
then
    if [ \( ! -z "${ARG_LOCAL_DIR}" \) -o \( ! -z "${ARG_NIM_DIR}" \) ]
    then
        print -u2 "ERROR: you cannot use '--use-nfs' with '--local-dir' and/or NIM parameters"
        exit 1
    fi
    if [[ -z "${ARG_NFS_DIR}" ]]
    then
        print -u2 "ERROR: you must specify a value for parameter '--nfs-dir'"
        exit 1
    fi
fi
# --use-nim/--nim-dir
if (( ARG_USE_NIM != 0 ))
then
    if [ \( ! -z "${ARG_LOCAL_DIR}" \) -o \( ! -z "${ARG_NFS_DIR}" \) ]
    then
        print -u2 "ERROR: you cannot use '--use-nim' with '--local-dir' and/or NFS parameters"
        exit 1
    fi
    if [[ -z "${ARG_NIM_DIR}" ]]
    then
        print -u2 "ERROR: you must specify a value for parameter '--nim-dir'"
        exit 1
    fi
fi
# --log-dir
[[ -z "${ARG_LOG_DIR}" ]] || LOG_DIR="${ARG_LOG_DIR}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
if (( ARG_LOG != 0 ))
then
    if [ \( ! -d "${LOG_DIR}" \) -o \( ! -w "${LOG_DIR}" \) ]
    then
        print -u2 "ERROR: unable to write to the log directory at ${LOG_DIR}"
        exit 1    
    fi
fi
# --mail-to/--send-alert
if [ \( ! -z "${ARG_MAIL_TO}" \) -a \( ${ARG_SEND_ALERT} -eq 0 \) ]
then
    print -u2 "ERROR: you cannot specify '--mail-to' without '--send-alert'"
    exit 1

fi

return 0
}

# -----------------------------------------------------------------------------
function check_platform
{
if [[ "$(uname -s)" != "AIX" ]]
then
    print -u2 "ERROR: must be run on an AIX system"
    exit 1
fi

return 0
}

# -----------------------------------------------------------------------------
function check_run_user
{
(IFS='()'; set -- $(id); print $2) | read UID
if [[ "${UID}" != "${EXEC_USER}" ]]
then
    print -u2 "ERROR: must be run as user '${EXEC_USER}'"
    exit 1
fi

return 0
}

# -----------------------------------------------------------------------------
function die
{
NOW="$(date '+%d-%h-%Y %H:%M:%S')"

if [[ -n "$1" ]]
then
    if (( ARG_LOG != 0 ))
    then
        print - "$*" | while read LOG_LINE
        do
            print "${NOW}: ERROR: [$$]:" "${LOG_LINE}" >>${LOG_FILE}
        done
    fi
    print - "$*" | while read LOG_LINE
    do
        print -u2 "ERROR:" "${LOG_LINE}"
    done
    (( ARG_SEND_ALERT != 0 )) && send_alert "$1"
fi

# finish up work
do_cleanup

exit 1
}

# -----------------------------------------------------------------------------
function display_usage
{
cat << EOT

**** ${SCRIPT_NAME} ****
**** (c) KUDOS BVBA - UNIX (Patrick Van der Veken) ****

Performs an mksysb, backupios, viosbr backup of an AIX/VIOS host to a
local, NIM-based or NFS location; optionally creates a snap of the host.

Syntax: ${SCRIPT_NAME} [--help] | [--version] | (--local-dir=<local_directory> | 
                --use-nfs --nfs-dir=<remote_directory> |
                    --use-nim --nim-dir=<remote_directory>)
                        [--is-vios [--is-ivm]]
                            [--make-snap] [--no-log] [--log-dir=<log_directory>]
                                [--send-alert [--mail-to=<address_list>]]

                                
Parameters:

--is-ivm        - perform a bkprofdata backup for VIOS using IVM (non-HMC)
--is-vios       - perform a backup using viosbr (IOS 2.1+) and backupios
                  tools if the client host is a VIO server.
--local-dir     - location of the save directory on a local filesystem.
--log-dir       - specify a log directory location.
--mail-to       - list of e-mail address(es) to which e-mails will to be send to.
--make-snap     - make an AIX snap (cfr. IBM support).
--nfs-dir       - location of the save directory on the NFS server. Format must be in typical
                  NFS mount notation, i.e. nfs_srv:/nfs_dir.
--nim-dir       - location of the save directory on the NIM master server. Client hostname
                  is automatically appended to the given value when automounting the directory.
--no-log        - do not log any messages to the script log file.
--send-alert    - alert via e-mail upon occurrence of errors/warnings.
--use-nfs       - create the backup on a NFS mount shared by an NFS server. 
                  See Pre-requisites section below.
--use-nim       - create the backup on a NFS mount shared by the NIM master. 
                  See Pre-requisites section below.
--version       : show the script version/release/fix

Pre-requisites for the NIM method:
    1) NIM master must be configured to allow NFS mount from the client to the remote 
       target directory. The NFS mount name must end in the NIM client's hostname
       (see /etc/xtab, /etc/exports on NIM master).
    2) NIM client (this host) must have AutoFS configured & active for /net 
       (see /etc/auto_master).
    3) A correctly configured /etc/niminfo file on the NIM client.
     
Pre-requisites for the NFS method:
    1) NFS server must be configured to allow NFS mount from the client to the remote 
       target directory (see /etc/xtab, /etc/exports on NFS server)

Note 1: NIM & NFS methods both employ a remote NFS mount for storage and as such they operate
        in a similar manner. The NIM method differs in that it will try auto-discover which
        host is the NIM master. In both cases you must have forward & reverse naming resolution
        working correctly!        

Note 2: please make sure sufficient disk space is available at the save location to hold 
        3 generations of backups during execution of the script. Only 2 generations will 
        be available at any given time (one being temporary). You will find these generations
        as the 'prev' and 'curr' directory sets in the save location.

EOT

return 0
}

# -----------------------------------------------------------------------------
function do_cleanup
{
log "performing cleanup ..."
# remove working directory
if [[ -d ${WORK_DIR} ]]
then
    rm -rf ${WORK_DIR} >/dev/null
    log "${WORK_DIR} working directory removed"
fi
# disable temporary mountpoint for NFS method
if (( ARG_USE_NFS != 0 ))
then
    log "trying to unmount ${TARGET_DIR}"
    umount ${TARGET_DIR} >/dev/null
    RC_NFS=$?
    if (( RC_NFS == 0 ))
    then
        log "succesfully unmounteded ${TARGET_DIR}"
        # remove temporary mount point
        rm -rf ${TARGET_DIR} >/dev/null
    else
        warn "could not unmount ${TARGET_DIR}, please check! [RC=${RC_NFS}]"
    fi
fi
# remove lock directory
if [[ -d ${LOCK_DIR} ]]
then
    rm -rf ${LOCK_DIR} >/dev/null
    log "${LOCK_DIR} lock directory removed"
fi

log "*** finish of ${SCRIPT_NAME} [${CMD_LINE}] ***"

return 0
}

# -----------------------------------------------------------------------------
function log
{
NOW="$(date '+%d-%h-%Y %H:%M:%S')"

if [[ -n "$1" ]]
then
    if (( ARG_LOG != 0 ))
    then
        print - "$*" | while read LOG_LINE
        do
            print "${NOW}: INFO: [$$]:" "${LOG_LINE}" >>${LOG_FILE}
        done
    fi
    if (( ARG_VERBOSE != 0 ))
    then
        print - "$*" | while read LOG_LINE
        do
            print "INFO:" "${LOG_LINE}"
        done
    fi
fi

return 0
}

# -----------------------------------------------------------------------------
function send_alert
{
NOW="$(date '+%d-%h-%Y %H:%M:%S')"
SUBJ_MSG="[${HOST_NAME}] ${SCRIPT_NAME} alert (${NOW})"
TEXT_MSG="$1"

# override/set defaults
[[ -n "${ARG_MAIL_TO}" ]] && TO_MSG="${ARG_MAIL_TO}"
[[ -z "${FROM_MSG}" ]] && FROM_MSG="${EXEC_USER}@${HOST_NAME}"

# build message components
cat <<EOT | sendmail -t 
To: ${TO_MSG}
Subject: ${SUBJ_MSG}
From: ${FROM_MSG}

MESSAGE: ${TEXT_MSG}

Please check the log file ${LOG_FILE} at ${HOST_NAME} for more details.

*** END OF MAIL. DO NOT REPLY TO THIS E-MAIL. NOBODY WILL SEE IT! ***

EOT
log "sent alert to ${TO_MSG}"

return 0
}

# -----------------------------------------------------------------------------
function warn
{
NOW="$(date '+%d-%h-%Y %H:%M:%S')"

if [[ -n "$1" ]]
then
    if (( ARG_LOG != 0 ))
    then
        print - "$*" | while read LOG_LINE
        do
            print "${NOW}: WARN: [$$]:" "${LOG_LINE}" >>${LOG_FILE}
        done
    fi
    if (( ARG_VERBOSE != 0 ))
    then
        print - "$*" | while read LOG_LINE
        do
            print "WARN:" "${LOG_LINE}"
        done
    fi
    (( ARG_SEND_ALERT != 0 )) && send_alert "$1"
fi

return 0
}


#******************************************************************************
# MAIN routine
#******************************************************************************

# parse arguments/parameters
CMD_LINE="$@"
for PARAMETER in ${CMD_LINE}
do
    case ${PARAMETER} in
        -is-ivm|--is-ivm)
            ARG_IS_IVM=1
            ;;    
        -is-vios|--is-vios)
            ARG_IS_VIOS=1
            ;;
        -log-dir=*)
            ARG_LOG_DIR="${PARAMETER#-log-dir=}"
            ;;
        --log-dir=*)
            ARG_LOG_DIR="${PARAMETER#--log-dir=}"
            ;;
        -nfs-dir=*)
            ARG_NFS_DIR="${PARAMETER#-nfs-dir=}"
            ;;
        --nfs-dir=*)
            ARG_NFS_DIR="${PARAMETER#--nfs-dir=}"
            ;;
        -nim-dir=*)
            ARG_NIM_DIR="${PARAMETER#-nim-dir=}"
            ;;
        --nim-dir=*)
            ARG_NIM_DIR="${PARAMETER#--nim-dir=}"
            ;;
        -mail-to=*)
            ARG_MAIL_TO="${PARAMETER#-mail-to=}"
            ;;
        --mail-to=*)
            ARG_MAIL_TO="${PARAMETER#--mail-to=}"
            ;;            
        -make-snap|--make-snap)
            ARG_MAKE_SNAP=1
            ;;
        -local-dir=*)
            ARG_LOCAL_DIR="${PARAMETER#-local-dir=}"
            ;;
        --local-dir=*)
            ARG_LOCAL_DIR="${PARAMETER#--local-dir=}"
            ;;
        -send-alert|--send-alert)
            ARG_SEND_ALERT=1;
            ;;
        -use-nfs|--use-nfs)
            ARG_USE_NFS=1
            ;;
        -use-nim|--use-nim)
            ARG_USE_NIM=1
            ;;
        -no-log|--no-log)
            ARG_LOG=0
            ;;
        -V|-version|--version)
            print "INFO: $0: ${AIX_VRF}"
            exit 0
            ;;
        \? | -h | -help | --help)
            display_usage
            exit 0
            ;;
    esac    
done

# startup checks
check_params && check_run_user && check_platform

# catch shell signals
trap 'do_cleanup; exit' 1 2 3 15

log "*** start of ${SCRIPT_NAME} [${CMD_LINE}] ***"    
(( ARG_LOG != 0 )) && log "logging takes places in ${LOG_FILE}"  

# check/create lock file & write PID file
check_lock_dir

# -----------------------------------------------------------------------------
# determine target location
# -----------------------------------------------------------------------------

# set local target
if (( ARG_USE_NIM == 0 && ARG_USE_NFS == 0 ))
then
    log "using local target ${ARG_LOCAL_DIR} for backup"
    TARGET_DIR=${ARG_LOCAL_DIR}
fi

# set & mount NFS target
if (( ARG_USE_NFS != 0 ))
then
    log "using NFS mount for backup"
    # ready NFS mount    
    TARGET_DIR="${TMP_DIR}/$$"
    mkdir -p ${TARGET_DIR} >/dev/null || die "failed to create NFS mountpoint at ${TARGET_DIR}"
    mount ${ARG_NFS_DIR} ${TARGET_DIR} >/dev/null
    RC_NFS=$?
    if (( RC_NFS == 0 ))
    then
        log "NFS directory ${ARG_NFS_DIR} mounted onto ${TARGET_DIR}"
    else
        die "could not NFS mount ${ARG_NFS_DIR} to ${TARGET_DIR} [RC=${RC_NFS}]"
    fi
fi

# set & mount NIM target
if (( ARG_USE_NIM != 0 ))
then
    log "using NIM mount for backup"
    # source NIM info file
    [[ -f /etc/niminfo ]] || die "/etc/niminfo file is missing for NIM-based backup"
    . /etc/niminfo
    [[ -z "${NIM_MASTER_HOSTNAME}" ]] && die "could not determine NIM master name"
    # chop a leading slash
    ARG_NIM_DIR="$(print ${ARG_NIM_DIR#/*})"
    [[ -z "${ARG_NIM_DIR}" ]] && \
        die "could not determine save location from '--nim-dir' value"
    # ready NIM NFS mount
    TARGET_DIR="/net/${NIM_MASTER_HOSTNAME}/${ARG_NIM_DIR}/${HOST_NAME}"
    cd ${TARGET_DIR} >/dev/null
    cd - >/dev/null
    # check that we have the NIM mount
    CHECK_NIM=$(mount | grep -c -E -e "^${NIM_MASTER_HOSTNAME}.*${TARGET_DIR}")
    (( CHECK_NIM == 0 )) && die "could not automount ${TARGET_DIR}"
fi

# -----------------------------------------------------------------------------
# do backup(s)
# -----------------------------------------------------------------------------

# set temporary backup directory
WORK_DIR="${TARGET_DIR}/${SCRIPT_NAME}.$$"
mkdir ${WORK_DIR} >/dev/null || \
    die "could not create backup working directory in ${WORK_DIR}"
chmod 700 ${WORK_DIR} >/dev/null

# check for VIOS?
if [ \( ARG_IS_VIOS != 0 \) -a \( -n "${VIOS_VERSION}" \) ]
then
    log "VIOS check: running on a VIO server [${VIOS_VERSION}]"
    # run VIOSBR, only on ioslevel 2.1+
    case "${VIOS_VERSION}" in
        1.*|2.0*)
            log "VIOSBR backup not supported on this ioslevel, skipping"
            ;;        
        2.*)
            # check standard backup directory
            if [[ ! -d /home/padmin/cfgbackups ]]
            then
                mkdir -p /home/padmin/cfgbackups >/dev/null
                chown padmin /home/padmin/cfgbackups >/dev/null
            fi
            log "starting the VIOSBR backup in /home/padmin/cfgbackups ..."
            TIMESTAMP="$(date '+%Y%m%d')"
            /usr/ios/cli/ioscli viosbr -backup -file ${HOST_NAME}_${TIMESTAMP}.viosbr >${WORK_DIR}/viosbr.log 2>&1
            RC_VIOSBR=$?
            if (( RC_VIOSBR == 0 ))
            then
                [[ -f /home/padmin/cfgbackups/${HOST_NAME}_${TIMESTAMP}.viosbr.tar.gz ]] && \
                    cp -p /home/padmin/cfgbackups/${HOST_NAME}_${TIMESTAMP}.viosbr.tar.gz ${WORK_DIR}
                if (( $? == 0 ))
                then
                    chmod 600 ${WORK_DIR}/${HOST_NAME}_${TIMESTAMP}.viosbr.tar.gz >/dev/null
                    log "VIOSBR file created and copied to ${WORK_DIR}"
                else
                    warn "failed to move VIOSBR file to ${WORK_DIR}"    
                fi                
            else
                warn "failed to create VIOSBR file [RC=${RC_VIOSBR}]"
            fi
            ;;
        *)
            log "VIOSBR backup not supported on this ioslevel, skipping"
            ;;
    esac
    # run bkprofdata (IVM only, non-HMC)
    if (( ARG_IS_IVM != 0 ))
    then
        log "starting the BKPROFDATA backup in /home/padmin ..."
        TIMESTAMP="$(date '+%Y%m%d')"   
        su - padmin -c "bkprofdata -o backup -f ${HOST_NAME}_${TIMESTAMP}.bkprofdata"
        RC_BKPROFDATA=$?
            if (( RC_BKPROFDATA == 0 ))
            then
                [[ -f /home/padmin/${HOST_NAME}_${TIMESTAMP}.bkprofdata ]] && \
                    cp -p /home/padmin/${HOST_NAME}_${TIMESTAMP}.bkprofdata ${WORK_DIR}
                if (( $? == 0 ))
                then
                    chmod 600 ${WORK_DIR}/${HOST_NAME}_${TIMESTAMP}.bkprofdata >/dev/null
                    log "BKPROFDATA file created and copied to ${WORK_DIR}"
                else
                    warn "failed to move BKPROFDATA file to ${WORK_DIR}"    
                fi                
            else
                warn "failed to create BKPROFDATA file [RC=${RC_BKPROFDATA}]"
            fi  
    
    fi
    # run backupios
    log "starting the BACKUPIOS backup in ${WORK_DIR} ..."
    /usr/ios/cli/ioscli backupios -file ${WORK_DIR}/${HOST_NAME}.backupios >${WORK_DIR}/backupios.log 2>&1
    RC_BACKUPIOS=$?
    if (( RC_BACKUPIOS == 0 ))
    then
        log "BACKUPIOS file created at ${WORK_DIR}/${HOST_NAME}.backupios"
        chmod 600 ${WORK_DIR}/${HOST_NAME}.backupios >/dev/null
    else
        warn "failed to create BACKUPIOS file at ${WORK_DIR}/${HOST_NAME}.backupios [RC=${RC_BACKUPIOS}]"
    fi    
else
    # run MKSYSB
    log "VIOS check: running on regular AIX host or no '--is-vios' given"
    log "starting the MKSYSB backup in ${WORK_DIR} ..."
    mksysb -i -e ${WORK_DIR}/${HOST_NAME}.mksysb >${WORK_DIR}/mksysb.log 2>&1
    RC_MKSYSB=$?
    if (( RC_MKSYSB == 0 ))
    then
        log "MKSYSB file created at ${WORK_DIR}/${HOST_NAME}.mksysb"
        chmod 600 ${WORK_DIR}/${HOST_NAME}.mksysb >/dev/null
    else
        warn "failed to create MKSYSB file at ${WORK_DIR}/${HOST_NAME}.mksysb [RC=${RC_MKSYSB}]"
    fi
fi
    
# run SNAP
if (( ARG_MAKE_SNAP != 0 ))
then
    log "requested a SNAP, creating one at the default location ..."
    snap -ac >${WORK_DIR}/snap.log 2>&1
    RC_SNAP=$?
    if (( RC_SNAP == 0 ))
    then
        [[ -f /tmp/ibmsupt/snap.pax.Z ]] && mv /tmp/ibmsupt/snap.pax.Z ${WORK_DIR}
        if (( $? == 0 ))
        then
            chmod 600 ${WORK_DIR}/snap.pax.Z >/dev/null
            log "SNAP file created and moved to ${WORK_DIR}"
        else
            warn "failed to move SNAP file to ${WORK_DIR}"    
        fi
    else
        warn "failed to create SNAP at default location [RC=${RC_SNAP}]"
    fi
fi

# handle backup generations, we only discard the current backup 
# if RC_MKSYSB != 0 or RC_BACKUPIOS != 0
log "rotating backup generations ..."
if (( RC_MKSYSB == 0 && RC_BACKUPIOS == 0 ))
then
    [[ -d ${TARGET_DIR}/prev ]] && rm -rf ${TARGET_DIR}/prev >/dev/null
    [[ -d ${TARGET_DIR}/curr ]] && mv ${TARGET_DIR}/curr ${TARGET_DIR}/prev >/dev/null
    mv ${WORK_DIR} ${TARGET_DIR}/curr >/dev/null
    log "available backup(s) are now:"
    log "$(ls -ld ${TARGET_DIR}/*)"
fi
    
# finish up work
do_cleanup

#******************************************************************************
# END of script
#******************************************************************************
