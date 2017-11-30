#!/bin/bash
########################################################################################
#				AUTOSETOGG					       #	
#			      Author:Castiel					       #
#	1.此脚本用于配置Godengate + Oracle + DDL 单双向同步。			       #
#	2.此脚本可配置源与目标，先在源端执行，脚本将自动完成各项进程创建。	       #
#	3.脚本会检测Oracle和Goldengate环境，请确保以上环境都已正确安装。	       #
#	4.脚本会自动配置Oracle和Goldengate环境，非首次运行多个步骤可跳过。	       #
#	5.脚本在Oracle 10g、Oracle 11g与Goldengate 12c环境下测试。		       #
#	6.**配置双向同步时表清单输入需保持一致，并使用SOURCE-TARGET的格式。**	       #
#	7.**配置完成若从目标端无法同步到源端且进程正常情况下请在源端执行	       #
#	    SEND REPLICAT REPLICAT HANDLECOLLISIONS 待正常同步之后再执行	       #
#	    SEND REPLICAT REPLICAT NOHANDLECOLLISIONS				       #
#	8.配置使用默认端口7809，动态端口7910-7890，请确保防火墙开启以上端口。	       #
#                                                                                      #
#	10.安装配置顺序建议:(在此之前请先确定oracle与goldengate已安装完成)	       #
#	  1.源端执行此脚本配置基础环境与EXTRACT 、DATAPUMP、REPLICAT 进程。	       #
#	  2.手动运行GGSCI并启动EXTRACT和DATAPUMP 并观察进程是否有异常终止。	       #
#	  3.确定以上进程正常运行后将源端数据库以FLASHBACK_SCN方式备份(建议使用exp)。   #
#	  4.在目标端使用imp将源端备份的文件还原，完成数据库的初始化装载。	       #
#	  5.在目标端运行此脚本配置对应的REPLICAT进程，使用AFTERCSN FLASHCSN方式启动。  #
#	  6.测试从SOURCE到TARGET同步是否正常。					       #
#	  7.若开启双向同步再启动目标端EXTRACT和DATAPUMP进程，观察进程是否有异常终止。  #
#	  8.启动目标端的REPLICAT进程，测试从TARGET到SOURCE同步是否正常。	       #
#	  9.在初始化装载过程中，备份源数据库之前请确保所有事务均已提交。	       #
#										       #
########################################################################################
stty erase "^H"

echo -e "\033[34m    _   _   _ _____ ___  ____  _____ _____    ___   ____  ____ \033[0m"
echo -e "\033[34m   / \ | | | |_   _/ _ \/ ___|| ____|_   _|  / _ \ / ___|/ ___|\033[0m"
echo -e "\033[34m  / _ \| | | | | || | | \___ \|  _|   | |   | | | | |  _| |  _ \033[0m"
echo -e "\033[34m / ___ \ |_| | | || |_| |___) | |___  | |   | |_| | |_| | |_| |\033[0m"
echo -e "\033[34m/_/   \_\___/  |_| \___/|____/|_____| |_|    \___/ \____|\____|\033[0m"
echo " "
echo " "
#echo " "
DEBUG=1
TEMPDIR="/usr/tmp"
TEMPFILE="$TEMPDIR/tmpfile"

function stdout(){
  if [ "$1" != "" ];then
	if [ "$2" != "" ];then
		case "$2" in
        		INFO) echo -e "\033[32m$1\033[0m";if [ $DEBUG == 0 ];then echo "$1" >>./setogg.log;fi;;
			ERROR) echo -e "\033[31m$1\033[0m";if [ $DEBUG == 0 ];then echo "$1" >>./setogg.log;fi;;
			WARNING) echo -e "\033[33m$1\033[0m";if [ $DEBUG == 0 ];then echo "$1" >>./setogg.log;fi;;
		esac
	else
		echo -e "\033[36m$1\033[0m"
	fi
  fi
}

function tolower()
{
    echo $1| tr '[A-Z]' '[a-z]'
}

function toupper()
{
    echo $1| tr '[a-z]' '[A-Z]'
}


stdout "Welcom to use AUTOSET OGG.\nThis script will automatically configure the source server and the target server, please select the operation according to the script prompt."
echo -e " "

#ORACLE 环境检
sqlplus -h >/dev/null 2>&1

if [ $? != 0 ];then
 stdout "[!]ERROR:The sqlplus program cannot be detected. Please confirm that Oracle Database has been installed and configured." ERROR
 exit
fi
oravs=`sqlplus -V | awk '{printf $3}' | awk -F '.' '{print $1}'`

stdout "[+]INFO:Get Oracle version:`sqlplus -V | awk '{printf $3}'`" INFO

echo -e "\033[33m"

read -p "Enter ORACLE_SID for configuring Oracle GoldenGate (Default $ORACLE_SID):" ORACLE_SID_INPUT

if [ "$ORACLE_SID_INPUT" != "" ];then
	ORACLE_SID=$ORACLE_SID_INPUT
fi

export ORACLE_SID=$ORACLE_SID

#获取OGG安装路径
OGG_HOME=$OGG_HOME
read -p "Enter Oracle GoldenGate installation directory (Default $OGG_HOME):" OGG_HOME_INPUT;

if [ "$OGG_HOME_INPUT" != "" ];then
	OGG_HOME=$OGG_HOME_INPUT
fi

if [ -f "$OGG_HOME/ggsci" ]
  then
  	stdout "[+]INFO:Get the Oracle GoldenGate installation directory:$OGG_HOME" INFO
  else
	stdout "[!]ERROR:The ggsci file cannot be detected. Please verify that the Oracle GoldenGate installation directory is correct." ERROR
	exit 
  fi

echo -e "\033[33m"

while ( [ "$USEFOR" != "SOURCE" ] && [ "$USEFOR" != "TARGET" ] );do
	read -p "This server will be the SOURCE or TARGET:" USEFOR;
	USEFOR=`toupper $USEFOR`
done

while ( [ "$ACTIVE" != "YES" ] && [ "$ACTIVE" != "NO" ] );do
	read -p "Configuring Oracle GoldenGate for Active-Active High Availability?(YES/NO):" ACTIVE
	ACTIVE=`toupper $ACTIVE`
done


##################################################设置数据库log模式开始##################################################

if ( [ "$USEFOR" == "SOURCE" ] || ( [ "$USEFOR" == "TARGET" ] && [ "$ACTIVE" == "YES" ] ) );then
	[ -f $TEMPDIR/SET_LOG.SQL ] && mv $TEMPDIR/SET_LOG.SQL $TEMPDIR/SET_LOG.SQL.BAK


	#设置归档模式archivelog
	sqlplus / as sysdba<<_EOF >$TEMPFILE
	archive log list
_EOF


	stdout "`cat $TEMPFILE`" INFO
	archlog=`cat $TEMPFILE | grep "Automatic archival" | awk '{print $3}'`

	#archlog="Disabled"
	if [ "$archlog" != "" ] && [ "$archlog" == "Disabled" ];then
		stdout "[-]WARNING:Archivelog is currently Disabled.Write SQL file now." WARNING
		sqlstr="-------打开数据库归档模式-------\n"
		sqlstr+="shutdown immediate;\n"
		sqlstr+="startup mount;\n"
		sqlstr+="alter database archivelog;\n"
		sqlstr+="alter database open;\n"
		sqlstr+="archive log list;\n"
		echo -e $sqlstr >> $TEMPDIR/SET_LOG.SQL
	elif [ "$archlog" != "" ] && [ "$archlog" == "Enabled" ];then
		stdout "[+]INFO:Archivelog is currently Enabled" INFO
	else
		stdout "[!]ERROR:Unable to get archivelog state,Please check log files."
		exit
	fi

	
	#设置force logging
	sqlplus / as sysdba<<_EOF >$TEMPFILE
	select 'FORCELOG '||force_logging from v\$database;
_EOF

	stdout "`cat $TEMPFILE`" INFO
	forcelog=`cat $TEMPFILE | grep FORCELOG | awk '{print $2}' | sed '/^$/d'`

	#forcelog="NO"
	if [ "$forcelog" != "" ] && [ "$forcelog" == "NO" ];then
        	stdout "[-]WARNING:Forcelog is currently Disabled.Write SQL file now." WARNING
	        sqlstr="-------打开force logging---------\n"
        	sqlstr+="alter database force logging;\n"
	        sqlstr+="select force_logging from v\$database;\n"
        	echo -e $sqlstr >> $TEMPDIR/SET_LOG.SQL
	elif [ "$forcelog" != "" ] && [ "$forcelog" == "YES" ];then
        	stdout "[+]INFO:Forcelog is currently Enabled" INFO
	else
        	stdout "[!]ERROR:Unable to get forcelog state,Please check log files."
		exit
	fi


	#设置supplemental log
	sqlplus / as sysdba<<_EOF >$TEMPFILE
	select 'SUPPLOG '||supplemental_log_data_min from v\$database;
_EOF

	stdout "`cat $TEMPFILE`" INFO

	supplog=`cat $TEMPFILE | grep SUPPLOG | awk '{print $2}' | sed '/^$/d'`

	#supplog="NO"
	if [ "$supplog" != "" ] && [ "$supplog" == "NO" ];then
        	stdout "[-]WARNING:Supplemental log is currently Disabled.Write SQL file now." WARNING
	        sqlstr="-------打开supplemental log-------\n"
        	sqlstr+="alter database add supplemental log data;\n"
	        sqlstr+="alter system switch logfile;\n"
		sqlstr+="select supplemental_log_data_min from v\$database;\n"
	        echo -e $sqlstr >> $TEMPDIR/SET_LOG.SQL
	elif [ "$supplog" != "" ] && [ "$supplog" == "YES" ];then
        	stdout "[+]INFO:Supplemental log is currently Enabled" INFO
	else
        	stdout "[!]ERROR:Unable to get supplemental log state,Please check log files."
		exit
	fi


	#如果是ORACLE 10g 还需要关闭回收站
	if [ "$oravs" == "10" ];then
		sqlplus / as sysdba<<_EOF >$TEMPFILE
		show parameter recyclebin;
_EOF

		stdout "`cat $TEMPFILE`" INFO

		recycle=`cat $TEMPFILE | grep recyclebin | awk '{print $3}'`
	
		#recycle="on"
		if [ "$recycle" != "" ] && [ "$recycle" == "on" ];then
        		stdout "[-]WARNING:Recyclebin is currently ON and Oracle version is 10g.Write SQL file now." WARNING
        		sqlstr="-------关闭回收站-------\n"
	        	sqlstr+="alter system set recyclebin=off scope=both;\n"
        		sqlstr+="show parameter recyclebin;\n"
        		echo -e $sqlstr >> $TEMPDIR/SET_LOG.SQL
		elif [ "$recycle" != "" ] && [ "$recycle" == "OFF" ];then
        		stdout "[+]INFO:Recyclebin is currently OFF" INFO
		else
        		stdout "[!]ERROR:Unable to get recyclebin state,Please check log files."
			exit
		fi

	fi

echo -e "\033[33m"

	if ( [ "$archlog" == "Disabled" ] || [ "$forcelog" == "NO" ] || [ "$supplog" == "NO" ] );then

		confrm=""
		if [ "$archlog" == "Disabled" ];then
			while ( [ "$confrm" != "YES" ] && [ "$confrm" != "NO" ] );do
				read -p "Will the next operation briefly close the database to confirm this operation?(YES/NO):" confrm
				confrm=`toupper $confrm`
			done
		fi
		if [ "$confrm" != "NO" ];then
			echo "exit;" >> $TEMPDIR/SET_LOG.SQL
			stdout "[+]INFO:Execute the ORACLE base configuration file SET_LOG.SQL" INFO
			sqlplus / as sysdba @$TEMPDIR/SET_LOG.SQL > $TEMPFILE
			stdout "`cat $TEMPFILE`" INFO
		else	
			stdout "[+]INFO:Exit by user on set logs." INFO
			exit
		fi
	else
		stdout "[+]INFO:The ORACLE infrastructure has been completed." INFO
	fi
fi

##################################################设置数据库log模式结束##################################################


##################################################为OGG创建ORACLE用户开始################################################

#取得数据库路径

sqlplus / as sysdba<<_EOF >$TEMPFILE
select 'DIR '||name from v\$datafile where rownum<=1;
_EOF

datadir=`cat $TEMPFILE | grep DIR | awk '{print $2}' | sed '/^$/d'`
datadir=`dirname $datadir`


while [ "$created" != "done" ];do

	echo -e "\033[33m"

	read -p "Create oracle users for Oracle Goldengate:" ogguser
	
	ogguser_tmp=`toupper $ogguser`
	
	#检查用户是否存在
	sqlplus / as sysdba<<_EOF >$TEMPFILE
	select 'COUNT '||count(1) from dba_users where username='$ogguser_tmp';
_EOF

	count=`cat $TEMPFILE | grep COUNT | awk '{print $2}' | sed '/^$/d'`
	if [ $count -gt 0 ];then

		stdout "[!]ERROR:The user already exists to use other user names." ERROR
		
		skip=""		
		echo -e "\033[33m"
		
		while [ "$skip" != "YES" ] && [ "$skip" != "NO" ];do
			read -p "Do you want to skip?(YES/NO):" skip
			skip=`toupper $skip`
			if [ "$skip" != "NO" ];then
                        	created="done"
                	fi
		done
		
		while [ "$loginsucess" != "True" ];do
			echo -e "\033[33m"

			read -p "Ener the password of $ogguser to login:" password
			#验证登录
			cd $OGG_HOME && ./ggsci<<_EOF >$TEMPFILE
			DBLOGIN USERID $ogguser@$ORACLE_SID,PASSWORD $password
_EOF
			stdout "`cat $TEMPFILE`" INFO
			#loginsucess=`cat $TEMPFILE | grep Successfully | awk '{print $4}'`
			cat $TEMPFILE | grep Successfully > /dev/null
			if [ "$?" -eq "0" ];then
				loginsucess="True"
			else
				stdout "[!]ORA-01017: invalid username/password; logon denied." ERROR
			fi
		done

	else
		read -p "Password for Oracle user $ogguser:" password
		#read -p "Encryption password?(YES/NO):" encrypt
		
		#创建SQL
		sqlstr="create tablespace $ogguser datafile '$datadir/$ogguser.dbf' size 100m autoextend on next 100m maxsize 20480m;\n"
		sqlstr+="create temporary tablespace $ogguser""_temp"" tempfile '$datadir/$ogguser""_temp"".dbf' size 100m autoextend on next 100m maxsize 20480m;\n"
		sqlstr+="create user $ogguser identified by $password default tablespace $ogguser temporary tablespace $ogguser""_temp"" quota unlimited on users;\n"
		sqlstr+="grant connect,resource,dba to $ogguser;\n"
		sqlstr+="grant execute on utl_file to $ogguser;\n"
		sqlstr+="exit;"
		echo -e $sqlstr > $TEMPDIR/CREATE_USER.SQL

		#执行SQL
                sqlplus / as sysdba @$TEMPDIR/CREATE_USER.SQL > $TEMPDIR/tmpfile
                stdout "`cat $TEMPFILE`" INFO


		#检查用户是否创建成功
        	sqlplus / as sysdba<<_EOF >$TEMPFILE
	        select 'COUNT '||count(1) from dba_users where username='$ogguser_tmp';
_EOF
	
        	count=`cat $TEMPFILE | grep COUNT | awk '{print $2}' | sed '/^$/d'`
	        if [ $count -eq 0 ];then
                	stdout "[!]ERROR:Create user fails,check log files."
        	        exit
	        fi

		created="done"
	fi

done

if [ "$ogguser" != "" ] && [ "$password" != "" ];then
	
	#使用ggsci将用户密码加密
        $OGG_HOME/ggsci <<_EOF >$TEMPFILE
        ENCRYPT PASSWORD $password,ENCRYPTKEY DEFAULT
_EOF
        stdout "`cat $TEMPFILE`" INFO
        encpassword=`cat $TEMPFILE | grep password: | awk '{print $3}'`
        stdout "Password encrypted:$encpassword"
fi

##################################################为OGG创建ORACLE用户结束################################################

######################################################安装配置DDL########################################################

echo -e "\033[33m"

while [ "$setupddl" != "YES" ] && [ "$setupddl" != "NO" ];do
        read -p "User created.Do you want to setup DDL?(YES/NO):" setupddl
	setupddl=`toupper $setupddl`
done

if [ "$setupddl" != "YES" ];then
	stdout "[+]INFO:Skip by user on setupdll"
else
	stdout "Starting setup DDL,Please enter the username $ogguser following steps."

	if ( [ "$USEFOR" == "SOURCE" ] || ( [ "$USEFOR" == "TARGET" ] && [ "$ACTIVE" == "YES" ] ) );then

		cd $OGG_HOME && sqlplus / as sysdba @marker_setup.sql
		if [ $? != 0 ];then
			stdout "[!]ERROR:Execute marker_setup.sql failed,check log files."
			exit
		fi

		cd $OGG_HOME && sqlplus / as sysdba @ddl_setup.sql
		if [ $? != 0 ];then
        	        stdout "[!]ERROR:Execute ddl_setup.sql failed,check log files."
                	exit
	        fi

		cd $OGG_HOME && sqlplus / as sysdba @role_setup.sql
		if [ $? != 0 ];then
        	        stdout "[!]ERROR:Execute role_setup.sql failed,check log files."
                	exit
	        fi

	        sqlplus / as sysdba<<_EOF >$TEMPFILE
        	grant GGS_GGSUSER_ROLE to $ogguser;
_EOF
		stdout "`cat $TEMPFILE`" INFO

	fi
fi

######################################################安装配置DDL结束########################################################


######################################################配置OGG进程开始########################################################

echo -e "\033[33m"

while [ "$groups" != "YES" ] && [ "$groups" != "NO" ];do
	echo -e "\033[33m"
	read -p "All basic environment configurations are completed.Do you want to configure groups?(YES/NO):" groups
	groups=`toupper $groups`
done

if [ "$groups" != "YES" ];then
	stdout "[+]INFO:Skip by user on configure groups."
	exit
else
    function sourcegrp(){
	if [ "$ACTIVE" == "YES" ];then
		tranlogexclude="TRANLOGOPTIONS EXCLUDEUSER $ogguser"
		getupdatebefor="GETUPDATEBEFORES"
	fi
	while [ "$extdone" != "done" ];do
		echo -e "\033[33m"
		read -p "Enter EXTRACT name for source server,Only EIGHT characters are allowed:" extname
		if [ `echo $extname | wc -L` -gt 8 ];then
			stdout "Only EIGHT characters are allowed.Please retry."
		else
			extdone="done"
		fi
	done
	stdout "Get EXTRACT name:$extname" INFO
	
	echo -e "\033[33m"

	while [ "$exttdone" != "done" ] || [ "$chkextfile" != "no" ];do
		echo -e "\033[33m"
		read -p "Enter EXTRAIL file name for extract $extname,Only TWO characters are allowed:" exttrail
		if [ `echo $exttrail | wc -L` -gt 2 ];then
			stdout "Only TWO characters are allowed.Please retry"
		else
			exttdone="done"
		fi
		
		if [ "`ls $OGG_HOME/dirdat/ | grep ^$exttrail | wc -l`" -ne 0 ];then
			stdout "[!]The EXTTRAIL file already exists.Please use other." ERROR
		else
			chkextfile="no"
		fi
	done
	stdout "Get EXTTRAIL file name:$exttrail" INFO
	
	echo -e "\033[33m"
	
	while [ "$extpump" != "done" ];do
                echo -e "\033[33m"
                read -p "Enter Data Pump name for source server,Only EIGHT characters are allowed:" pumpname
                if [ `echo $pumpname | wc -L` -gt 8 ];then
                        stdout "Only EIGHT characters are allowed.Please retry."
                else
                        extpump="done"
                fi
        done
        stdout "Get Data Pump name:$pumpname" INFO
	
	#如果是Target 则先配置REPLICAT $rmttrail已赋值
	while ( [ "$rmtt" != "done" ] && [ "$rmttrail" == "" ] ) || [ "$chkrmtfile" != "no" ];do
                echo -e "\033[33m"
                read -p "Enter RMTTRAIL file name for Data Pump $pumpname,Only TWO characters are allowed:" rmttrail
                if [ `echo $rmttrail | wc -L` -gt 2 ];then
                        stdout "Only TWO characters are allowed.Please retry"
                else
                       rmtt="done"
                fi

		if [ "`ls $OGG_HOME/dirdat/ | grep ^$rmttrail | wc -l`" -ne 0 ];then
                        stdout "[!]The RMTTRAIL file already exists.Please use other." ERROR
                else
                        chkrmtfile="no"
                fi

        done
        stdout "Get RMTTRAIL file name:$rmttrail" INFO

	while [ "$ipchk" != "True" ];do
                echo -e "\033[33m"
                read -p "Enter the RMTHOST for Data Pump process:" rmthost
                ipcalc -cs $rmthost
                if [ $? -eq 0 ];then
                        ipchk="True"
                else
                        stdout "bad IPv4 address:$rmthost,Please retry." ERROR
                fi
        done
        stdout "Get TMTHOST:$rmthost" INFO

	
	while [ "$chktb" != "True" ] && [ "$tables" == "" ];do
		echo -e "\033[33m"

		read -p "Enter the table name that needs to be synchronized in this format:<owner>.<table>,Wildcards are allowed:" tables
		echo $tables | grep "-" > /dev/null
		if [ "$?" != 0 ] && [ "$ACTIVE" == "YES" ];then
			stdout "ERROR:To configuring for Active-Active High Availability, it should be in SOURCE-TARGET(<owner>.<table>) format."
		else
			chktb="True"

			tables=`echo $tables | sed s/[[:space:]]//g`
		        tables=`echo ${tables//,/ }`
		fi
	done
	
	for elem in ${tables[@]}
	do
		str=(${elem//-/ })
		if [ "$USEFOR" == "SOURCE" ];then
                	table_tmp+="TABLE "${str[0]}";\n"
                	addtran_tmp+="ADD TRANDATA "${str[0]}"\n"
		else
			table_tmp+="TABLE "${str[1]}";\n"
                        addtran_tmp+="ADD TRANDATA "${str[1]}"\n"
		fi
	done
	
	extfile="$OGG_HOME/dirprm/`tolower $extname`.prm"
	pumpfile="$OGG_HOME/dirprm/`tolower $pumpname`.prm"
	
	#创建抽取进程
	stdout "INFO:Starting create EXTRACT Process." INFO
	cd $OGG_HOME && ggsci<<_EOF >$TEMPFILE
	ADD EXTRACT $extname,TRANLOG,BEGIN NOW
	ADD EXTTRAIL ./dirdat/$exttrail,EXTRACT $extname,MEGABYTES 100
	ADD EXTRACT $pumpname,EXTTRAILSOURCE ./dirdat/$exttrail,BEGIN NOW
	ADD RMTTRAIL ./dirdat/$rmttrail,EXTRACT $pumpname,MEGABYTES 100
	DBLOGIN USERID $ogguser@$ORACLE_SID,PASSWORD $password
_EOF
	stdout "`cat $TEMPFILE`" INFO
	
	#确保在启动抓取进程后所有的事务均已提交

	trans_done="True"

	sqlplus / as sysdba<<_EOF >$TEMPFILE
	select 'SCN '||current_scn from v\$database;
_EOF

	current_scn=`cat $TEMPFILE | grep SCN | awk '{print $2}' | sed '/^$/d'`
	
	sqlplus / as sysdba<<_EOF >$TEMPFILE
	select 'SCN '||min(start_scn) from v\$transaction;
_EOF
	trans_scn=`cat $TEMPFILE | grep SCN | awk '{print $2}' | sed '/^$/d'`

	if [ "$trans_scn" != "" ] && [ "$trans_scn" -lt "$current_scn" ];then
		trans_done="False"
	fi

	#创建抽取进程文件
	stdout "INFO:Starting create EXTRACT Process File for $extname." INFO
	cat <<_EOF >$extfile
EXTRACT $extname
USERID $ogguser@$ORACLE_SID,PASSWORD $encpassword,ENCRYPTKEY default
EXTTRAIL ./dirdat/$exttrail
DISCARDFILE ./dirdat/discar.log,APPEND,MEGABYTES 100
DDL INCLUDE MAPPED
DDLOPTIONS ADDTRANDATA
$tranlogexclude
FETCHOPTIONS, USESNAPSHOT, NOUSELATESTVERSION, MISSINGROW REPORT
STATOPTIONS REPORTFETCH
WARNLONGTRANS 1H, CHECKINTERVAL 5M
$getupdatebefor
`echo -e $table_tmp`
_EOF
	chmod 640 $extfile
	stdout "EXTRACT Process has been created."
	stdout "`cat $extfile`" INFO

	#创建Datapump进程文件
	stdout "INFO:Starting create Datapump Process File for $pumpname." INFO
	cat <<_EOF >$pumpfile
EXTRACT $pumpname
USERID $ogguser@$ORACLE_SID,PASSWORD $encpassword,ENCRYPTKEY default
RMTHOST $rmthost, MGRPORT 7809,COMPRESS,COMPRESSTHRESHOLD 0
RMTTRAIL ./dirdat/$rmttrail
DISCARDFILE ./dirdat/discar.log,APPEND,MEGABYTES 100
PASSTHRU
`echo -e $table_tmp`
_EOF
	chmod 640 $pumpfile
	stdout "Datapump Process has been created."
	stdout "`cat $pumpfile`" INFO
}

   function targetgrp(){

	while [ "$replicat" != "done" ];do
                echo -e "\033[33m"
                read -p "Enter REPLICAT Process name for target server,Only EIGHT characters are allowed:" replicatname
                if [ `echo $replicatname | wc -L` -gt 8 ];then
                        stdout "Only EIGHT characters are allowed.Please retry."
                else
                        replicat="done"
                fi
        done
        stdout "Get REPLICAT name:$replicatname" INFO

        #如果是SOURCE 则先配置DATAPUMP $rmttrail已赋值
        while ( [ "$rmtt" != "done" ] && [ "$rmttrail" == "" ] ) || [ "$chkrmtfile" != "no" ];do
                echo -e "\033[33m"
                read -p "Enter RMTTRAIL file name for REPLICAT $replicatname,Only TWO characters are allowed:" rmttrail
                if [ `echo $rmttrail | wc -L` -gt 2 ];then
                        stdout "Only TWO characters are allowed.Please retry"
                else
                       rmtt="done"
                fi

		if [ "`ls $OGG_HOME/dirdat/ | grep ^$rmttrail | wc -l`" -ne 0 ];then
                         stdout "[!]The RMTTRAIL file already exists.Please use other." ERROR
                 else
                         chkrmtfile="no"
                fi
        done
        stdout "Get RMTTRAIL file name:$rmttrail" INFO

	while [ "$chktb" != "True" ] && [ "$tables" == "" ];do
		echo -e "\033[33m"

                read -p "Enter the table name that needs to be synchronized in this format:<owner>.<table>,Wildcards are allowed:" tables
                echo $tables | grep "-" > /dev/null
                if [ "$?" != 0 ] && [ "$ACTIVE" == "YES" ];then
                        stdout "ERROR:To configuring for Active-Active High Availability, it should be in SOURCE-TARGET(<owner>.<table>) format."
                else
                        chktb="True"

                        tables=`echo $tables | sed s/[[:space:]]//g`
                        tables=`echo ${tables//,/ }`
                fi
        done
        
        for elem in ${tables[@]}
        do
                str=(${elem//-/ })
		if [ "$USEFOR" == "SOURCE" ];then
			maptb="MAP "${str[1]}" , TARGET "${str[0]}";\n"
		else
			maptb="MAP "${str[1]}" , TARGET "${str[0]}";\n"	
		fi
        done
	
	#检查CHECKPOINTTABLE是否已经创建
	
	sqlplus $ogguser/$password<<_EOF >$TEMPFILE
select table_name from user_tables;
_EOF
	if [ "`cat $TEMPFILE | grep CHECKPOINT | wc -l`" -ne 0 ];then
		stdout "[+]INFO:Checkpoint table $ogguser.checkpoint already exists."
	else
		#创建checkpoint
	        stdout "Starting add checkpoint table."
	        cd $OGG_HOME && ggsci<<_EOF >$TEMPFILE
        	DBLOGIN USERID $ogguser@$ORACLE_SID,PASSWORD $password
	        ADD CHECKPOINTTABLE $ogguser.checkpoint
_EOF
		stdout "`cat $TEMPFILE`"
	fi
	
	repfile="$OGG_HOME/dirprm/`tolower $replicatname`.prm"

	#创建REPLICAT进程
	stdout "INFO:Starting create REPLICAT Process." INFO
        cd $OGG_HOME && ggsci<<_EOF >$TEMPFILE
	ADD REPLICAT $replicatname,EXTTRAIL ./dirdat/$rmttrail,CHECKPOINTTABLE $ogguser.checkpoint
_EOF
        stdout "`cat $TEMPFILE`"
	
	#创建REPLICAT进程文件
	stdout "INFO:Starting create REPLICAT Process File for $replicatname." INFO
        cat <<_EOF >$repfile
REPLICAT $replicatname
ASSUMETARGETDEFS
USERID $ogguser@$ORACLE_SID,PASSWORD $encpassword,ENCRYPTKEY default
DISCARDFILE ./dirdat/discar.log,APPEND,MEGABYTES 100
DDL INCLUDE MAPPED
DDLOPTIONS REPORT
BATCHSQL
DBOPTIONS DEFERREFCONST
DBOPTIONS LOBWRITESIZE 102400
DDLERROR DEFAULT DISCARD RETRYOP MAXRETRIES 5 RETRYDELAY 20
`echo -e $maptb`
_EOF
        chmod 640 $repfile
        stdout "Replicat Process has been created."
        stdout "`cat $repfile`" INFO
	
}

   #统计ORACLE数据库(两种方式)
   if [ "`cat /etc/oratab | grep / | wc -l`" -gt 1 ] || [ "`ps -ef | grep ora_pmon | wc -l`" -gt 2 ];then
	setenv="true"
   fi

   GGSCHEMA="GGSCHEMA $ogguser"

   if ( [ "$USEFOR" == "TARGET" ] || ( [ "$USEFOR" == "SOURCE" ] && [ "$ACTIVE" == "YES" ] ) );then
	checkpoint="CHECKPOINTTABLE $ogguser.checkpoint"
   fi
   
   #创建GLOBALS文件
   [ -f $OGG_HOME/GLOBALS ] && mv $OGG_HOME/GLOBALS $OGG_HOME/GLOBALS.BAK 
	echo -e $GGSCHEMA>$OGG_HOME/GLOBALS
	echo -e $checkpoint>>$OGG_HOME/GLOBALS
	chmod 640 $OGG_HOME/GLOBALS
	stdout "[+]INFO:GLOBALS file has been created." INFO
	stdout "`cat $OGG_HOME/GLOBALS`" INFO

   #创建MANAGER进程
  if [ -f $OGG_HOME/dirprm/mgr.prm ];then
	while [ "$skipmgr" != "YES" ] && [ "$skipmgr" != "NO" ];do
		echo -e "\033[33m"
		read -p "The MANAGER process file already exists, Do you want to skip?(YES/NO):" skipmgr
		skipmgr=`toupper $skipmgr`
		
	done 
  fi

  if [ "$skipmgr" != "YES" ];then
	cat <<_EOF >$OGG_HOME/dirprm/mgr.prm
PORT 7809
DYNAMICPORTLIST 7810-7890
USERID $ogguser@$ORACLE_SID,PASSWORD $encpassword,ENCRYPTKEY default
AUTORESTART ER *, RETRIES 3, WAITMINUTES 5
CHECKMINUTES 30
LAGREPORTHOURS 1
LAGINFOMINUTES 30
LAGCRITICALMINUTES 30
STARTUPVALIDATIONDELAY 5
PURGEOLDEXTRACTS ./dirdat/*, USECHECKPOINTS, MINKEEPFILES 10
PURGEDDLHISTORY MINKEEPDAYS 3, MAXKEEPDAYS 5, FREQUENCYMINUTES 30
PURGEMARKERHISTORY MINKEEPDAYS 3, MAXKEEPDAYS 5, FREQUENCYMINUTES 30
_EOF
	chmod 640 $OGG_HOME/dirprm/mgr.prm
	stdout "[+]INFO:MANAGER has been created." INFO
	stdout "`cat $OGG_HOME/dirprm/mgr.prm`" INFO
  else
	stdout "[+]INFO:Skip by user on create MANAGER Process."
  fi

   if [ "$USEFOR" == "SOURCE" ];then
	sourcegrp

	#如果是双向同步，源需要以目标方式配置
	if [ "$ACTIVE" == "YES" ];then
		targetgrp
	fi
   else
	targetgrp
	
	#如果是双向同步，目标需要一源方式配置
	if [ "$ACTIVE" == "YES" ];then
                sourcegrp
        fi
   fi
fi

if [ "$trans_done" != "True" ];then
	stdout "There are uncommitted transactions before EXTRACT starts(START_SCN:$trans_scn),make sure they are committed before the initial load." WARNING
else
	stdout "All configurations have been completed.Please ensure that port 7909-7890 can be passed through the firewall."
fi

stdout "SERVER USE FOR:$USEFOR" INFO
stdout "SET ORACLE_SID:$ORACLE_SID" INFO
stdout "Active-Active High Availability:$ACTIVE" INFO
stdout "Oracle User for Goldengate:$ogguser,PASSWORD_ENCRYPT:$encpassword" INFO
stdout "Tables for synchronization:$tables" INFO
stdout "Synchronize to the remote server:$rmthost" INFO
stdout "The default port:7809" INFO
stdout "Dynamic port list:7810-7890" INFO
stdout "EXTTRAIL at $OGG_HOME/dirdat/$exttrail" INFO
stdout "RMTTRAIL at $OGG_HOME/dirdat/$rmttrail" INFO
