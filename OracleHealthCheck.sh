#!/bin/bash
#
# Purpose: Perform some checks of the databases
#
#   Usage: ksh oracle_health_check.sh (Best to avoid and use parameters instead)
#
#  v1.00  05-Mar-2017 Jim Rogers
#        Created  (adapted from previous script)
#
script_version="v2.00"
[[ $Debug = "y" ]] && echo "We have started the host script " `date "+%d-%m-%Y_%H-%M"` >>/tmp/Oracle_debug_$$
server=`hostname`

###    TestA
check_disk_space()
{

[[ $Debug = "y" ]] && echo "Disk Space check  "  >>/tmp/Oracle_debug_$$
##  should we run this?
if [ ${TestA0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Disk space checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi


# Make sure no partition is more than 90% full
#server=`hostname`
if [ "`df -hl | sort -u | egrep -v '/cdrom|Filesystem' | awk -v val=${TestA1:-80} 'int($5) >=val'`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font  face=\"Calibri\" color=\"red\" >    Disk space checks - FAILED:</font></p>" >>${mailfile}
  echo "<p>    Filesystem                    size   used  avail capacity  Mounted on</p>" >>${mailfile}
  printf "%s\n" "<p>  `df -h| egrep -v '/cdrom|Filesystem'| awk -v val=${TestA1:-80} 'int($5) >=val'`</p>" >>${mailfile}
else
  echo "<p><font  face=\"Calibri\">    Disk space  -OK</p>" >>${mailfile}
fi
}

###    TestB
check_database_connection()
{
[[ $Debug = "y" ]] && echo "Database Connectiona check " >>/tmp/Oracle_debug_$$
# Check database is up and open in normal mode and that a tns connect works

    connect_user="SYS"
    connect_check="connect"


temp_file=/tmp/oracle_health_check_tempfile_${ORACLE_SID}_$$
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ 2>&1 >$temp_file
show user;
+++

if [ "`grep $connect_user $temp_file`" ] && [ ! "`grep 'ORA-' $temp_file`" ]; then
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - $connect_check check -OK</p>" >>${mailfile}
  connect_check_ok=y
else
  echo "<p><font  face=\"Calibri\" color=\"red\">    $ORACLE_SID - $connect_check check FAILED</font></p>" >>${mailfile}
  echo "<p>Skipping the rest of database the checks</p>" >>${mailfile}
  cat $temp_file >>${mailfile}
  mailerror=y
  error=n											
  sids_in_error="${ORACLE_SID} ${sids_in_error}"
  connect_check_ok=n
fi
}


###    TestC
check_tablespace_free_space()
{
[[ $Debug = "y" ]] && echo "Tablespcae freespace check  " >>/tmp/Oracle_debug_$$
##  should we run this?
if [ ${TestC0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - tablespace checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

#echo "TestC1 is set to " ${TestC1}
#echo "TestC2 is set to " ${TestC2}
# Check there is not less than 15 free space in any tablespace
#   ${1:-oracle_test.lst}
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
set pagesize 1000
set linesize 130
col name for a30
col TIME for a20
col "Tablespace"          for a22
col "Allocated MB"        for 99,999,999.99
col "Used MB"             for 99,999,999.99
col "Free MB"             for 99,999,999.99
col "Total MB"            for 99,999,999.99
col "Extendable to"       for 99,999,999.99
col "Pct. Free"           for 999,999.99
col "maxspace"            for 999,999.99
prompt Tablespaces with less than ${TestC1:-15}% or ${TestC2:-100} GB free space:
select df.tablespace_name "Tablespace",
df.totalspace "Allocated MB",
nvl(totalusedspace,0) "Used MB",
(df.totalspace - nvl(tu.totalusedspace,0)) "Free MB",
round(100 * ( (df.totalspace - nvl(tu.totalusedspace,0))/ df.totalspace),2) "Pct. Free",
round(maxspace,2) "Extendable to",
round(100 * ( (maxspace - nvl(tu.totalusedspace,0))/ maxspace),2) "Pct Free of Max"
from
(select tablespace_name,
round(sum(bytes) / 1048576) TotalSpace
, sum(decode(maxbytes, 0, 32767, maxbytes/1024/1024)) maxspace
from dba_data_files
group by tablespace_name) df,
(select round(sum(bytes)/(1024*1024)) totalusedspace, tablespace_name
from dba_segments
group by tablespace_name) tu
 ,
(
 select tablespace_name, round(sum(bytes)/1024/1024 ,2) as free_space
       from dba_free_space
       group by tablespace_name
) fs
where df.tablespace_name = tu.tablespace_name(+)
AND df.tablespace_name = fs.tablespace_name(+)
and ( round(100 * ( (maxspace - nvl(tu.totalusedspace,0))/ maxspace),2)) < ${TestC1:-15}
and ((df.totalspace - nvl(tu.totalusedspace,0))/1024) < ${TestC2:-100}
ORDER BY "Pct. Free"
/
+++
if [ "`egrep -v '^Tablespaces|^Segments|^\ *$|^}|^<|^no rows selected' $temp_file`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - tablespace checks FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - tablespace checks -OK</p>" >>${mailfile}
fi
rm $temp_file
}

###    TestD
check_tablespace_storage()
{
[[ $Debug = "y" ]] && echo "Tablespace Storage check     " >>/tmp/Oracle_debug_$$
##  should we run this?
if [ ${TestD0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Extent checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

# Tablespace checks.
# Check that no segments withing 10 of max extents
# Check that there is enough room for each segments next extent
# Check that each tablespace has room for all its segments to grow at least once
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
column tablespace_name format a15
column owner           format a20
column segment_name    format a30
column segment_type    format a8
column bytes           format 999,999,999
column next_extent     format 999,999,999

prompt Segments close to maxextents (<= 10):
SELECT owner, segment_name, segment_type, extents
,max_extents, tablespace_name
FROM dba_segments
WHERE extents >= (max_extents-10)
AND segment_type != 'CACHE';

set verify off
set feedback off
set serveroutput on size 1000000
DECLARE
  num_segs INTEGER(10);
  space_required INTEGER(10);
  free_space INTEGER(10);
  heading INTEGER(2);
  error INTEGER(2);
BEGIN
  heading := 0;
  error := 0;
  FOR tablespace IN
    (select distinct tablespace_name
     from dba_data_files
     where tablespace_name not like 'ROLLBACKS%'
     and tablespace_name not in ('SYSAUX','SYSTEM'))
  LOOP
    select count(*) INTO num_segs from dba_segments
           where segment_type in ('TABLE','INDEX')
           and tablespace_name=tablespace.tablespace_name;
    select ceil(sum(s.next_extent*(1+t.pct_increase/100))/1048576) INTO space_required
           from dba_segments s, dba_tablespaces t
           where s.tablespace_name=t.tablespace_name
           and s.tablespace_name=tablespace.tablespace_name;
    select nvl(floor(sum(bytes/1024/1024)),0) INTO free_space from dba_free_space
           where tablespace_name=tablespace.tablespace_name;
    IF free_space < space_required THEN
      error := 1;
    END IF;
    IF error = 1 THEN
      IF heading = 0 THEN
        dbms_output.put_line ('tablespace       number of segments      space required      free space');
        heading := 1;
      END IF;
      dbms_output.put_line (tablespace.tablespace_name||'                       '||num_segs||'                  '||space_required||'            '||free_space);
      error := 0;
    END IF;
  END LOOP;
EXCEPTION
  WHEN OTHERS THEN
    dbms_output.put_line ('Unexpected exception   sqlcode :'||SQLCODE||'  sqlerrm : '||SQLERRM);
END;
/
set verify on
set feedback on
+++
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >>$temp_file
column tablespace_name format a15
column owner format a20
column segment_name format a30
column segment_type format a8
column bytes format 999,999,999
column next_extent format 999,999,999

prompt Segments with no room to extend:
select s.tablespace_name, s.owner, s.segment_name, s.segment_type, s.bytes, s.next_extent
from   dba_segments s
where  s.next_extent > (SELECT max(f.bytes)
                        FROM   dba_Free_space f
                        WHERE  s.tablespace_name = f.tablespace_name)
/

+++

if [ "`egrep -v '^Tablespaces|^Segments|^\ *$|^}|^<|^no rows selected' $temp_file`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - Extent checks FAILED</font></p>" >>${mailfile}
  echo >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - Extent checks -OK</p>" >>${mailfile}
fi
rm $temp_file
}

###    TestE
check_asm_free_space()
{
##set -xv
asmerror=NO

##  should we run this?
if [ ${TestE0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - ASM space checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

temp_fileE=/tmp/oracle_health_check_tempfileE_${ORACLE_SID}_$$
[[ $Debug = "y" ]] && echo "ASM check.....  " >>/tmp/Oracle_debug_$$
[[ $Debug = "y" ]] && echo "TestE1 is "${TestE1}  >>/tmp/Oracle_debug_$$
[[ $Debug = "y" ]] && echo "Oracle SID is "${ORACLE_SID} >>/tmp/Oracle_debug_$$
unset asm_msg
[[ -z ${TestE2} ]] &&  asm_msg=" or  ${TestE2}"
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_fileE
set linesize 130
column DISK format a10
col "% Free" for 99.99
column "size (GB)" format 999,999
prompt ASM Disks with less than ${TestE1:-20}% free space
prompt NOTE:         This does not include FRA  ${asm_msg}
select *
from (
select name "DISK", total_mb/1024 as "size (GB)", (FREE_MB/total_mb)*100 "% Free" from v\$asm_diskgroup where name not like 'FRA%' and name not like '${TestE2:-REDO}%'
)
where "% Free" < ${TestE1:-20}
/
+++

if [ "`egrep -v '^NOTE|^ASM Disks|^\ *$|^}|^<|^no rows selected' $temp_fileE`" ]; then
  error=y
  asmerror=y
  ((errorcount++))
  echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - ASM Freespace check failed</p>" >>${mailfile}
  echo >>${mailfile}
  cat $temp_fileE >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - ASM Freespace -OK</p>" >>${mailfile}
fi
 [[ $Debug = "n" ]] && rm $temp_fileE
unset temp_fileE
}

###    TestF
check_restore_points()
{
##  should we run this?
if [ ${TestF0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Restore Point checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

temp_file=/tmp/oracle_health_check_tempfile_RP_$$
[[ $Debug = "y" ]] && echo "Restore point check  " >>/tmp/Oracle_debug_$$
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
set feedback on
col  name for a30
col TIME for a20
SELECT NAME, TO_CHAR(TIME,'DD-MM-YYYY HH24:MI:SS') as time, SCN, GUARANTEE_FLASHBACK_DATABASE FROM V\$RESTORE_POINT;
+++
if [ "`grep -e '^no rows selected' $temp_file`" ]; then
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - No restore points found - OK</p>" >>${mailfile}
else
  error=y
  ((errorcount++))
  echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - Restore point found - FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
fi
#rm $temp_file
}

###    TestG
check_aum()
{
##  should we run this?
if [ ${TestG0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Auto Undo Management checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

 sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
  alter session set nls_date_format = 'yyyy/mm/dd hh24:mi';
  col undo_retention format a14
  set lines 120
  select begin_time, end_time, NOSPACEERRCNT as "Space errors in last 24hrs",
  p2.value as undo_retention, maxquerylen
  from v\$undostat u,
  (select value from v\$parameter where name = 'undo_management') p1,
  (select value from v\$parameter where name = 'undo_retention') p2
  where u.begin_time > sysdate -1
  and u.NOSPACEERRCNT > 0
  and p1.value = 'AUTO';
  exit;
+++
  if [ "`grep 'no rows selected' $temp_file`" ]; then
    echo "<p><font face=\"Calibri\">    $ORACLE_SID - Auto Undo Management space check -OK</p>" >>${mailfile}
  else
    error=y
        ((errorcount++))
    echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - Auto Undo Management space check FAILED</font></p>" >>${mailfile}
    cat $temp_file  >>${mailfile}
    echo >>${mailfile}
  fi

  sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
  alter session set nls_date_format = 'yyyy/mm/dd hh24:mi';
  col undo_retention format a14
  set lines 120
  select begin_time, end_time, SSOLDERRCNT as "ORA-1555 errors in last 24hrs",
  p2.value as undo_retention, maxquerylen
  from v\$undostat u,
  (select value from v\$parameter where name = 'undo_management') p1,
  (select value from v\$parameter where name = 'undo_retention') p2
  where u.begin_time > sysdate -1
  and u.SSOLDERRCNT > 0
  and p1.value = 'AUTO';
  exit;
+++
  if [ "`grep 'no rows selected' $temp_file`" ]; then
    echo "<p><font face=\"Calibri\">    $ORACLE_SID - Auto Undo Management undo_retention check -OK</p>" >>${mailfile}
  else
    error=y
        ((errorcount++))
    echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - Auto Undo Management undo_retention check FAILED</font></p>" >>${mailfile}
    cat $temp_file  >>${mailfile}
    echo >>${mailfile}
  fi
}

###    TestH
check_data_guard()
{
##  should we run this?
if [ ${TestH0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Data Guard Broker check skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

dgmgrl -silent / <<+++ > $temp_file
show configuration ;
exit ;
+++
# check for Broker errors
if [ "`grep 'ORA-' $temp_file`" -o "`grep 'database (disabled)' $temp_file`" -o "`grep 'Enabled:             NO' $temp_file`" ]; then
   error=y
   ((errorcount++))
   echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - Data Guard Broker check FAILED</font></p>" >> ${mailfile}
   cat $temp_file >> ${mailfile}
   echo "" >> ${mailfile}
else
   echo "<p><font face=\"Calibri\">    $ORACLE_SID - Data Guard Broker check -OK</p>" >> ${mailfile}
fi
}

###    TestI
check_active_data_guard ()
{
##  should we run this?
if [ ${TestI0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Active Data Guard checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

   temp_file=/tmp/oracle_health_check_tempfile_${ORACLE_SID}_$$
  sqlplus -s /nolog <<+++ >$temp_file
  connect / as sysdba
  select currently_used
  from dba_feature_usage_statistics
  where name = 'Active Data Guard - Real-Time Query on Physical Standby';
exit
+++
  if [ "`grep 'FALSE' $temp_file`"  -o "`grep 'no rows selected' $temp_file`"  -o "`grep 'ORA-01219' $temp_file`" ];
 then
   echo "<p><font face=\"Calibri\">    $ORACLE_SID - Active Data Guard check  -  its OFF" >>${mailfile}
  else
    Active=Yes
    echo "<p><font face=\"Calibri\">    $ORACLE_SID - Active Data Guard check -  its ON" >>${mailfile}
#    cat $temp_file | head >>${mailfile}
  fi

}

###    TestJ
check_dbsnmp_user ()
{
##  should we run this?
if [ ${TestJ0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - DBSNMP user check skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

sqlplus -s /nolog <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading off
  select  decode ( account_status, 'OPEN','Account_is_open', account_status) ,'EXISTS' from dba_users where username='DBSNMP';
  exit
+++

  if [[ $? -eq 0  ]]
    then
      echo "<p><font face=\"Calibri\">    $ORACLE_SID - DBSNMP User Exists - OK</p>" >>$mailfile
      grep -i Account_is_open $temp_file >/dev/null
      if [[ $? -eq 0 ]]
        then
          echo "<p><font face=\"Calibri\">    $ORACLE_SID - DBSNMP User Account Open - OK</p>" >>$mailfile
        else
          echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - DBSNMP User Account Locked - FAILED</font></p>" >>$mailfile
          error=y
        fi
    else
      echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - DBSNMP User Missing - FAILED</font></p>" >>$mailfile
      error=y
          ((errorcount++))
  fi

}

###    TestK
check_system_user ()
{
##  should we run this?
if [ ${TestK0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - RSystem user checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

sqlplus -s /nolog <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading off
  select  decode ( account_status, 'OPEN','Account_is_open', account_status) ,'EXISTS' from dba_users where username='SYSTEM';
  exit
+++

  if [[ $? -eq 0  ]]
    then
      grep -i Account_is_open $temp_file >/dev/null
      if [[ $? -eq 0 ]]
        then
          echo "<p><font face=\"Calibri\">    $ORACLE_SID - SYSTEM User Account Open - OK</p>" >>$mailfile
        else
          echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - SYSTEM User Account Locked - FAILED</font></p>" >>$mailfile
          error=y
                  ((errorcount++))
        fi
    else
      echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - SYSTEM User Missing - FAILED</font></p>" >>$mailfile
      error=y
  fi

}

###    TestL
backup_check ()
{
##  should we run this?
if [ ${TestL0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Backup checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

sqlplus -s /nolog <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading off
  select LOG_MODE from v\$database;
  exit
+++

grep -i NOARCHIVELOG $temp_file >/dev/null
    if [[ $? -eq 0 ]]
        then
            echo "  $ORACLE_SID - Database in NO Archive Log Mode ">>${mailfile}
    else
          if [ "`grep '^+ASM' $oratab`" ]
            then
            ORACLE_SID_SAV=$ORACLE_SID
            ORACLE_HOME_SAV=$ORACLE_HOME
            PATH_SAV=$PATH
            ORACLE_SID=`grep '^+ASM' $oratab | awk -F: '{print $1}'`; export ORACLE_SID
            ORACLE_HOME=`grep '^+ASM' $oratab | awk -F: '{print $2}'`; export ORACLE_HOME
            PATH=${ORACLE_HOME}/bin:/usr/local/bin:${the_path}; export PATH
            RAC_NODES=`olsnodes`
            ORACLE_SID=$ORACLE_SID_SAV
            ORACLE_HOME=$ORACLE_HOME_SAV
            PATH=$PATH_SAV
            if [[ $RAC_NODES == "" ]]; then
#             ASM is installed and olsnodes returns blank
              RAC=N
            else
#             ASM is installed and olsnodes shows a value
              RAC=Y
            fi
          else
#           No ASM installed so this is not a RAC
            RAC=N
          fi
          if [[ $RAC == "Y" ]]; then
#           Strip off leading character and last 2 from ORACLE_SID e.g. CPR1SRA1 becomes PR1SR
            CDF_AND_SWN_SID=`echo $ORACLE_SID | awk '{print substr($0,2,length($0)-3)}'`
          else
#           Strip off leading character and last character from ORACLE_SID e.g. CPR1BSA becomes PR1BS
            CDF_AND_SWN_SID=`echo $ORACLE_SID | awk '{print substr($0,2,length($0)-2)}'`
          fi
#         Change TNS_ADMIN location to use ORACLE Wallet and decided wether to connect
#         To PROD or NON PROD recovery catalog base on server name 
          export TNS_ADMIN=/u01/app/oracle/wallet
          if [[ "`echo $server |awk '{print substr($1,2,2)}'`" == "pr" ]]; then 
#           Use Prod Virtual Private Catalog
            vp_catalog_conn_str="CPRRCA1_VP_RCAT_PROD"
          else
#           Use NON Prod Virtual Private Catalog
            vp_catalog_conn_str="CPRRCA1_VP_RCAT_NONPROD"
          fi
          sqlplus -s /@${vp_catalog_conn_str} <<+++ >$temp_file
		set pages 999 heading off
		select 'No Datafile backup' from dual where not exists (select 'x' from RC_BACKUP_DATAFILE b,RC_DATABASE d 
                where d.NAME like '%${CDF_AND_SWN_SID}%' and d.DB_KEY=b.DB_KEY and COMPLETION_TIME > trunc(SYSDATE) - 1)
          	union
		select 'No Spfile backup' from dual where not exists (select 'x' from RC_BACKUP_SPFILE b,RC_DATABASE d 
                where d.NAME like '%${CDF_AND_SWN_SID}%' and d.DB_KEY=b.DB_KEY and COMPLETION_TIME > trunc(SYSDATE) - 1)
		union
		select 'No Controlfile backup' from dual where not exists (select 'x' from RC_BACKUP_CONTROLFILE_DETAILS b,RC_DATABASE d 
                where d.NAME like '%${CDF_AND_SWN_SID}%' and d.DB_KEY=b.DB_KEY and CHECKPOINT_TIME > trunc(SYSDATE) - 1)
		union
                select 'No Archive log backup' from dual where not exists (select 'x' from RC_BACKUP_ARCHIVELOG_DETAILS b,RC_DATABASE d 
                where  d.NAME like '%${CDF_AND_SWN_SID}%' and d.DB_KEY=b.DB_KEY and NEXT_TIME > trunc(SYSDATE) - 1);
		exit
+++
	  if [ "`egrep -v '^no rows selected' $temp_file`" ]; then
            error=y
            ((errorcount++))
            echo "<p><font color=\"red\" face=\"Calibri\">    %$CDF_AND_SWN_SID% - Backup checks FAILED:</font></p>" >>${mailfile}
            echo "<p><font face=\"Calibri\">    Backups not run in the last 24 hours </font></p>" >>${mailfile}
            cat $temp_file >>${mailfile}
          else
            echo "<p><font face=\"Calibri\">    $ORACLE_SID - No Missed Backups -OK</p>" >>${mailfile}
          fi
          sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" /@${vp_catalog_conn_str} <<+++ >$temp_file
		set lines 100
		col STATUS format a9
		col "Input GB" form 99999.99
		col "Output GB" form 99999.99
		col hrs format 999.99
		prompt Backup with errors over the last ${TestL1:-3} Days:
		select d.name,SESSION_KEY, INPUT_TYPE, STATUS,
		to_char(START_TIME,'mm/dd/yy hh24:mi') start_time,
		to_char(END_TIME,'mm/dd/yy hh24:mi') end_time,
		round(INPUT_BYTES/1024/1024/1024,2) "Input GB",
		round(OUTPUT_BYTES/1024/1024/1024,2) "Output GB",
		elapsed_seconds/3600 hrs 
                from RC_RMAN_BACKUP_JOB_DETAILS b ,RC_DATABASE d
 		where d.NAME like '%${CDF_AND_SWN_SID}%' and d.DB_KEY=b.DB_KEY 
                and START_TIME > trunc(SYSDATE) - ${TestL1:-3}
		and STATUS NOT in ('COMPLETED','RUNNING')
		order by session_key  desc;
+++
	   if [ "`egrep -v '^\ *$|^}|^<|^Backup with errors|^no rows selected' $temp_file`" ]; then
             error=y
             ((errorcount++))
             echo "<p><font color=\"red\" face=\"Calibri\">    %${CDF_AND_SWN_SID}% - Backup errors found FAILED:</font></p>" >>${mailfile}
             cat $temp_file >>${mailfile}
	   else
             echo "<p><font face=\"Calibri\">    %${CDF_AND_SWN_SID}% - No Backup errors -OK</p>" >>${mailfile}
           fi
#   Reset TNS_ADMIN variable
    export TNS_ADMIN=$ORACLE_HOME/network/admin
    fi
}

###    TestM
check_user_profiles ()
{
##  should we run this?
if [ ${TestM0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - User account checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading on define off
  col username for a30
  select username, profile, account_status from dba_users where account_status <>  'EXPIRED & LOCKED' and PROFILE NOT IN ( 'NOEXP', 'ADMIRAL_DEFAULT' )
  union
  select username, profile, account_status from dba_users where account_status not in ('OPEN','EXPIRED & LOCKED');
  exit
+++

if [ "`egrep -v '^\ *$|^}|^<|^no rows selected' $temp_file`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - User account checks FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - User account checks -OK</p>" >>${mailfile}
fi
rm $temp_file
}

###    TestN
check_invalid ()
{
if [ ${TestN0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Invalid Objects checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi
 
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading on define off
select owner , object_type, count(*) from dba_objects where status <> 'VALID'  group by owner, object_type;
  exit
+++

if [ "`egrep -v '^\ *$|^}|^<|^no rows selected' $temp_file`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - Invalid Objects checks FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - No Invalid Objects -OK</p>" >>${mailfile}
fi
rm $temp_file

}

###    TestO
check_unusable_indexes ()
{
##  should we run this?
if [ ${TestO0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Unusable Indexe checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading on define off
 select OWNER,INDEX_NAME, INDEX_TYPE,STATUS from dba_indexes where status = 'UNUSABLE';
  exit
+++

if [ "`egrep -v '^\ *$|^}|^<|^no rows selected' $temp_file`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - Unusable Indexes Found -  FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - Unusable Index  checks -OK</p>" >>${mailfile}
fi
rm $temp_file

}

###    TestP
check_FRA_free_space()
{
asmerror=NO

##  should we run this?
if [ ${TestP0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - FRA space checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

temp_fileP=/tmp/oracle_health_check_tempfileP_${ORACLE_SID}_$$

unset asm_msg
[[ ${TestP2} != "XXXX" ]] &&  asm_msg=" or  ${TestP2}"
sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_fileP
set linesize 130
column DISK format a10
col "% Free" for 99.99
column "size (GB)" format 999,999
prompt FRA Disk with less than ${TestP1:-20}% free space
select *
from (
select a.name "DISK", a.total_mb/1024 as "size (GB)", ((a.FREE_MB+b.SPACE_RECLAIMABLE/1024/1024)/a.total_mb)*100 as "% Free" 
from v\$asm_diskgroup a, v\$recovery_file_dest b where substr(b.name, 2)=a.name
)
where "% Free" < ${TestP1:-20}
/
+++

if [ "`egrep -v '^FRA Disk|^\ *$|^}|^<|^no rows selected' $temp_fileP`" ]; then
  error=y
  asmerror=y
  ((errorcount++))
  echo "<p><font face=\"Calibri\" color=\"red\">    $ORACLE_SID - FRA Freespace check failed</p>" >>${mailfile}
  echo >>${mailfile}
  cat $temp_fileP >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - FRA Freespace -OK</p>" >>${mailfile}
fi
 [[ $Debug = "n" ]] && rm $temp_fileP
unset temp_fileP
}

###    TestQ
check_log_gap ()
{
##  should we run this?
if [ ${TestQ0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Log Gap checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi

sqlplus -s -m "HTML ON TABLE 'BORDER="2"'" / as sysdba <<+++ >$temp_file
  connect / as sysdba
  set pages 99 heading on define off
 select 1 from v\$archive_gap;
  exit
+++

if [ "`egrep -v '^\ *$|^}|^<|^no rows selected' $temp_file`" ]; then
  error=y
  ((errorcount++))
  echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - Log Gap Detected -  FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - Log Gap check -OK</p>" >>${mailfile}
fi
rm $temp_file

}

###    TestR
check_service ()
{
##  should we run this?
if [ ${TestR0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Service Status checks skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi
temp_fileR=/tmp/test_$$
Service_Rep_file=/tmp/Serv_test_$$
Serror=0
echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - Service status checks - FAILED:</font></p>" > $Service_Rep_file
echo "" >> $Service_Rep_file
echo "        The database role is $DB_Role " >> $Service_Rep_file
srvctl status service -d ${Oracle_DB} > $temp_fileR
exec 3<${temp_fileR}
read  -u 3 Service_Line

while true
do

Service_Name=`echo $Service_Line | awk '{print $2}'`
Service_Status=`echo $Service_Line | awk '{print $4}'`
Service_Role=`srvctl config service -s $Service_Name -d $Oracle_DB |grep 'Service role:'|awk '{print $3}'`
Service_Enable=`srvctl config service -s $Service_Name -d $Oracle_DB |grep 'Service is'|awk '{print $3}'`
[[ $Debug = "y" ]] && echo "Service ${Service_Name} is ${Service_Enable}"
if [[ ${Service_Enable} = "disabled" ]]
then
    read  -u 3 Service_Line
    [[ $? -ne 0 ]] && break
    continue
fi
Actual_Status=`srvctl status service -s $Service_Name -d ${Oracle_DB}|awk '{print $7}'`
Prefered_Status=`srvctl config service -s $Service_Name -d $Oracle_DB|grep Preferred|awk '{print $3}'`
#Serror=0
#echo The name is $Service_Name, DB role is $DB_Role, Config is $Service_Role and the status is $Service_Status
[[ $Debug = "y" ]] &&  echo "$DB_Role:$Service_Role:$Service_Status"
case "$DB_Role:$Service_Role:$Service_Status" in

Primary:PRIMARY:not)
((Serror++))
echo "<p><font face=\"Calibri\">        $Service_Name:  Config is $Service_Role but the service is Not Running.</font></p>"   >> $Service_Rep_file
;;

Primary:PHYSICAL_STANDBY:running)
((Serror++))
echo "<p><font face=\"Calibri\">        $Service_Name:  Config is $Service_Role but the service is Running.</font></p>" >> $Service_Rep_file
;;

Primary:PRIMARY:running)
#Check that service is running on all nodes
if [[ "$Actual_Status" != "$Prefered_Status" ]]
then
((Serror++))
echo "<p><font face=\"Calibri\">        $Service_Name:  Should be running on $Prefered_Status but is running on $Actual_Status. </font></p>" >> $Service_Rep_file
fi
#
;;

Standby:PRIMARY:running)
((Serror++))
echo "<p><font face=\"Calibri\">        $Service_Name:  Config is $Service_Role but the service is Running.</font></p>" >> $Service_Rep_file
;;

Standby:PHYSICAL_STANDBY:not)
((Serror++))
echo "<p><font face=\"Calibri\">        $Service_Name:  Config is $Service_Role but the service is Not Running.</font></p>" >> $Service_Rep_file
;;

Standby:PHYSICAL_STANDBY:running)
#Check that service is running on all nodes
if [[ "$Actual_Status" != "$Prefered_Status" ]]
then
((Serror++))
echo "<p><font face=\"Calibri\">        $Service_Name:  Should be running on $Prefered_Status but is running on $Actual_Status. </font></p>" >> $Service_Rep_file
fi
#
;;

esac
#
  read  -u 3 Service_Line
[[ $? -ne 0 ]] && break
done
if [ $Serror -gt 0 ]         
   then
   error=y
   ((errorcount++))
    cat ${Service_Rep_file}  >>${mailfile}
else 
      echo "<p><font face=\"Calibri\">    $ORACLE_SID - Service check -OK</p>" >>${mailfile}
fi

[[ $Debug = "n" ]] && rm $temp_fileR
[[ $Debug = "n" ]] && rm $Service_Rep_file
}

###  This proc reads the check parameter file and sets variables accordingly.
set_test_variables ()
{
[[ $Debug = "y" ]] && echo ${line[@]}  >>/tmp/Oracle_debug_$$
[[ $Debug = "y" ]] && echo " The number of elements is " ${#line[@]}  >>/tmp/Oracle_debug_$$
[[ $Debug = "y" ]] && echo "Value to Match is " ${Match}  >>/tmp/Oracle_debug_$$
[[ $Debug = "y" ]] && echo "The mode is  " ${Mode}  >>/tmp/Oracle_debug_$$
counta=1
while [[ $counta -le ${#line[@]} ]]
do
    if [[ ${line[$counta]} == ${Match} || ${line[$counta]} == "ALL" ]]
        then
            ((counta++))
            until [[ ${line[$counta]:0:4} != Test ]]
        do
                    ((countb=$counta+1))
            if [[ ${Mode} = "Set" ]]
                then
                eval ${line[$counta]}=${line[$countb]}
            else
                unset ${line[$counta]}
            fi
            counta=$(expr $counta + 2)
            done
        else
            ((counta++))
    fi
done
}

###    TestS
check_incremental ()
{
if [ ${TestS0:-0000} = "SKIP" ] ; then
    echo "<p><font color=\"orange\" face=\"Calibri\">    $ORACLE_SID - Incremental backup check Skipped</font></p>" >>${mailfile}
    ((skipcount++))
    return
fi
count_inc=$(sqlplus -s /nolog <<+++
  connect / as sysdba
  set pages 999 heading off;
  select trunc(sysdate - max(checkpoint_time))   from v\$datafile_copy where file# =1;
  exit;
+++
)
if [ ${count_inc} -gt 9 ]; then
  error=y
  ((errorcount++))
  echo "<p><font color=\"red\" face=\"Calibri\">    $ORACLE_SID - Incremental backup check FAILED:</font></p>" >>${mailfile}
  cat $temp_file >>${mailfile}
else
  echo "<p><font face=\"Calibri\">    $ORACLE_SID - Incremental backup check -OK</p>" >>${mailfile}
fi

}


###
# Start of script
# main MAIN Main
###
#
#set -vx
#export Debug=y
export Debug=n
[[ $Debug = "y" ]] && echo "Start of the healthcheck script on " $hostname
#
rundate=`date '+%d-%b %H:%M'`
mailfile=/tmp/oracle_health_check_mailfile_$$
sendfile=/tmp/oracle_health_check_sendfile_$$
oratab=/etc/oratab

error=n
mailerror=n
linkcount=1
errorcount=0
skipcount=0

#####
# Server level Checks
#####
#echo "=========================================================================================" >>$mailfile
#echo "Starting check for "${server} >>$mailfile
#echo "=========================================================================================" >>$mailfile
#echo >>$mailfile
#
#
#  read parameter file
listfile=/var/tmp/OracleHealthCheck.params
[[ $Debug = "y" ]] && echo $listfile
exec 4<${listfile}
read -u 4 -a line
[[ $Debug = "y" ]] && echo ${line[@]}
[[ $Debug = "y" ]] && echo " The number of elements is " ${#line[@]}
#
####read parameter files
par_lst=/var/tmp/OracleHealthCheck.params
Match=SERVER
Mode=Set
set_test_variables

echo "<h2><font face=\"Calibri\">Server Checks for ${server}</h2>" >>${mailfile}

[[ $TestA0 != "SKIP" ]] && check_disk_space

the_path=$PATH

if [ ${TestE0:-Test} != "SKIP" ]
    then
    if [ "`grep '^+ASM' $oratab`" ]
        then
        ORACLE_SID=`grep '^+ASM' $oratab | awk -F: '{print $1}'`; export ORACLE_SID
        ORACLE_HOME=`grep '^+ASM' $oratab | awk -F: '{print $2}'`; export ORACLE_HOME
        PATH=${ORACLE_HOME}/bin:/usr/local/bin:${the_path}; export PATH
        check_asm_free_space
    else
        echo "<p><font face=\"Calibri\">    $ORACLE_SID - ASM not in use - OK</p>" >>$mailfile
    fi
fi
# Reset error flag before looping through databases
[[ $Debug = "y" ]] && echo "Server check gave error =" ${error} >>/tmp/Oracle_debug_$$
if [ "$error" = "y" ]; then
  mailerror=y
  error=n
fi
##  Unset checking variablesA
 [[ $Debug = "y" ]] && echo "Unsetting the test variables"
 [[ $Debug = "y" ]] && echo "matching is " ${Match}
Mode=Unset
set_test_variables



#####
# Database level checks
#####
 [[ $Debug = "y" ]] && echo "Starting the database loop.....  "
# Loop through databases in oratab which we wish to check
databases_to_check=`cat ${oratab} | egrep -v '^$|^#|^\*|^\+ASM|^-MGMTDB'`
 [[ $Debug = "y" ]] && echo "database to check.....  " ${databases_to_check} >>/tmp/Oracle_debug_$$
sids_in_error=" for "

IFS=$'\n'
for dbline in ${databases_to_check}
do
  [[ $Debug = "y" ]] && echo "dbline in is " ${dbline} >>/tmp/Oracle_debug_$$
  ORACLE_SID=`echo $dbline | awk -F: '{print $1}'`; export ORACLE_SID
  ORACLE_HOME=`echo $dbline | awk -F: '{print $2}'`; export ORACLE_HOME
  LD_LIBRARY_PATH=${ORACLE_HOME}/lib ; export LD_LIBRARY_PATH
  ohome="`echo $ORACLE_HOME | awk ' {  print substr( $1, index ( $1, "product" )+8) }'`"
  PATH=${ORACLE_HOME}/bin:/usr/local/bin:${the_path}; export PATH
  ##  set checking variablesA
  [[ $Debug = "y" ]] && echo "Setting the test variables"
  Match=${ORACLE_SID}
  DB_Role=Standby
  Mode=Set
  set_test_variables
  ##
 
  [[ $Debug = "y" ]] && echo "start of loop:   current SID is " $ORACLE_SID >>/tmp/Oracle_debug_$$

  ##  Check that entry in oratab is for instance.  Skip if not 
  #  if ls /u01/app/oracle/diag/rdbms/*/${ORACLE_SID}> /dev/null 2>&1
  [[ $Debug = "y" ]] && echo "directory check of  " /u01/app/oracle/diag/rdbms/`perl -e "print lc('$ORACLE_SID');"|cut -c1-1`*/${ORACLE_SID} >>/tmp/Oracle_debug_$$
  #if ls /u01/app/oracle/diag/rdbms/`perl -e "print lc('$ORACLE_SID');"|cut -c1-1`*/${ORACLE_SID}> /dev/null 2>&1
  #    then
  #     [[ $Debug = "y" ]] && echo "Directory found:    checking DB " $ORACLE_SID >>/tmp/Oracle_debug_$$
  #    else
  #    [[ $Debug = "y" ]] && echo "Directory NOT found " >>/tmp/Oracle_debug_$$
  #       continue
  #fi
  if ps -ef|grep ${ORACLE_SID}$ >/dev/null 2>&1
    then 
	    [[ $Debug = "y" ]] && echo  "we have a match "
	else 
	    [[ $Debug = "y" ]] && echo "not found"
		continue
	fi
    
  #  Check input parameter and skip entire SID.
 
  if [ ${TestSID:-0000} = "SKIP" ] ; then
     [[ $Debug = "y" ]] && echo "skipping all tests for ${ORACLE_SID}" >>/tmp/Oracle_debug_$$  
     continue
  fi


  echo >>${mailfile}
  echo "<h2><font face=\"Calibri\">Database check for $ORACLE_SID - $ohomei</h2>" >>${mailfile}


  check_database_connection

  if [ "$connect_check_ok" = "n" ]; then
    continue # skip rest of database checks
  fi

  if   [[ `echo $ORACLE_SID |tail -c 2` =~ ^[0-9]+$ ]]
    then
     if [ `echo $ORACLE_SID |tail -c 2` -gt 1 ]
       then
         echo "<hr  color=\"blue>\" SIZE=\"3\">" >>$mailfile
         echo "<p><font face=\"Calibri\">Skipping other checks for $ORACLE_SID as already checked 01  RAC instance</p>" >>${mailfile}
         echo "<hr color=\"blue>\" SIZE=\"4\">" >>$mailfile
         echo "<br>" >>$mailfile
         echo "<p><a href=\"#TheTop\" style=\"color:blue;font-size:75%;font_family=Calibri\">TOP </a></p>" >>$mailfile
         echo "<br>" >>$mailfile
         echo "<br>" >>$mailfile
        continue
    fi
  fi

  Active=No
   if [ "`ps -ef | grep $ORACLE_SID | grep dmon`" ]; then
    check_log_gap
	check_data_guard
    check_active_data_guard
  fi

  check_FRA_free_space
  [[ $Debug = "y" ]] && echo  "Active is " $Active
#
  if [ $Active = "Yes" ] 
  then
      check_tablespace_storage
   fi
  check_restore_points


  
rm $temp_file
  sqlplus -s /nolog <<+++ >$temp_file
  connect / as sysdba
  set pages 999 heading off
  select database_role from v\$database;
  exit
+++

grep -i "PHYSICAL STANDBY" $temp_file >/dev/null
    if [[ $? -ne 0 ]]
        then
  DB_Role=Primary
  check_aum
  check_tablespace_free_space
  check_dbsnmp_user
  check_system_user
  check_user_profiles
  backup_check
  check_invalid
  check_unusable_indexes
fi

#Find Database name
cat <<EOF > /tmp/sqlplus_get_DB_$$.sql
SET PAGESIZE 0
    SET NEWPAGE 0
    SET SPACE 0
    SET LINESIZE 80
    SET ECHO OFF
    SET FEEDBACK OFF
    SET VERIFY OFF
    SET HEADING OFF
    select DB_UNIQUE_NAME from v\$database;
exit;
EOF
Oracle_DB=( $(sqlplus -S / as sysdba < /tmp/sqlplus_get_DB_$$.sql ) )

  check_service
  check_incremental

  #####   End of checks
  ##  set checking variables
  [[ $Debug = "y" ]] && echo "Unsetting the test variables"
  Match=${ORACLE_SID}
  Mode=UnSet
  set_test_variables
  ##
 
  echo "<hr  color=\"blue>\" SIZE=\"3\">" >>$mailfile
  echo "<p><font face=\"Calibri\">End of checks for  ${server} </p>"  >>$mailfile
  echo "<hr color=\"blue>\" SIZE=\"4\">" >>$mailfile
  echo "<br>" >>$mailfile
  echo "<p><a href=\"#TheTop\" style=\"color:blue;font-size:75%;font_family=Calibri\">TOP </a></p>" >>$mailfile
  echo "<br>" >>$mailfile
  echo "<br>" >>$mailfile

  #  compile the subject line if there was an error for this sid
  [[ $Debug = "y" ]] && echo "ERROR flag is " ${error} >>/tmp/Oracle_debug_$$
  if [ "$error" = "y" ]; then
    mailerror=y
    error=n
    sids_in_error="${sids_in_error} ${ORACLE_SID}"
  fi

done
## set the check skip message
unset skip_msg
if [ ${skipcount} -gt 0 ];
  then
    if [  ${skipcount} -eq 1 ];
      then
        export skip_msg=": ${skipcount} check has been skipped."
      else
        export skip_msg=": ${skipcount} checks have been skipped." 
    fi
fi

[[ ${#sids_in_error} -eq 5 ]] && unset sids_in_error
link=`echo $server | awk -F. '{print $1}'`

if [ "$mailerror" = "y" ];
  then
    echo "<hr  color=\"blue>\" SIZE=\"3\">" >>$sendfile
    echo "<a name=\"${link}\"></a>" >>$sendfile
    echo "<h2><a href=\"#${link}\" style=\"color:red;font-size:55%;font_family=Calibri\">WARNING:    ORACLE HEALTH CHECK found ${errorcount} issues on ${server} ${sids_in_error}  ${skip_msg} </a></h2>" >>$sendfile
    echo "<h2><font face=\"Calibri\" color=\"red\">WARNING:    ORACLE HEALTH CHECK found ${errorcount} issues on ${server} ${sids_in_error}  </font></h2>" >>$sendfile
    echo "<hr  color=\"blue>\" SIZE=\"3\">" >>$sendfile
    echo "<br>" >>$sendfile
  else
    echo "<hr  color=\"blue>\" SIZE=\"3\">" >>$sendfile
    echo "<a name=\"${link}\"></a>" >>$sendfile
    echo "<h2><a href=\"#${link}\" style=\"color:green;font-size:55%;font_family=Calibri\">ORACLE HEALTH CHECK for  ${server}  OK  ${skip_msg}</a></h2>" >>$sendfile
    echo "<h2><font face=\"Calibri\" color=\"green\">ORACLE HEALTH CHECK for  ${server} OK </font></h2>" >>$sendfile
    echo "<hr  color=\"blue>\" SIZE=\"3\">" >>$sendfile
    echo "<br>" >>$sendfile
fi
  cat ${mailfile}>>${sendfile}

  cat ${sendfile}

# Clean up all log files
  [[ $Debug = "n" ]] && rm /tmp/oracle_health_check*_$$

