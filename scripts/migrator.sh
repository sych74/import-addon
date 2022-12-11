#!/bin/bash -e

SUCCESS_CODE=0
FAIL_CODE=99
AUTHORIZATION_ERROR_CODE=701
RUN_LOG="/var/log/migrator.log"
SSH="timeout 300 sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST} -p${SSH_PORT}"
SSH_CREDS=
REMOTE_DIR="public_html"
BASE_DIR="/root/cpanel/wordpress"
BACKUP_DIR="/${BASE_DIR}/backup"
PROJECT_DIR="${BASE_DIR}/project"
WP_CONFIG="wp-config.php"
SSH_CONFIG="${BASE_DIR}/sshcreds"

[[ -d ${BASE_DIR} ]] && mkdir -p ${BASE_DIR}
[[ -d ${BACKUP_DIR} ]] && mkdir -p ${BACKUP_DIR}
[[ -d ${PROJECT_DIR} ]] && mkdir -p ${PROJECT_DIR}

log(){
  local message="$1"
  local timestamp
  timestamp=`date "+%Y-%m-%d %H:%M:%S"`
  echo -e "[${timestamp}]: ${message}" >> ${RUN_LOG}
}

execAction(){
  local action="$1"
  local message="$2"
  stderr=$( { ${action}; } 2>&1 ) && { log "${message}...done"; } || {
    error="${message} failed, please check ${RUN_LOG} for details"
    log "${message}...failed\n==============ERROR==================\n${stderr}\n============END ERROR================";
    exit 0
  }
}

execSshAction(){
  local action="$1"
  local message="$2"
  action_to_base64=$(echo $action|base64 -w 0)
  stderr=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { log "${message}...done"; } || {
    error="${message} failed, please check ${RUN_LOG} for details"
    log "${message}...failed\n==============ERROR==================\n${stderr}\n============END ERROR================";
    exit 0
  }
}

execSshReturn(){
  local action="$1"
  local message="$2"
  local result=${FAIL_CODE}
  action_to_base64=$(echo $action|base64 -w 0)
  stdout=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { echo ${stdout}; log "${message}...done"; } || {
    error="${message} failed, please check ${RUN_LOG} for details"
    log "${message}...failed\n==============ERROR==================\n${stdout}\n============END ERROR================";
    exit 0
  }
}

validatePublicHtmlDir(){
  local command="${SSH} \"[[ -d ${REMOTE_DIR} ]] && {  echo 'true'; } || { echo 'false';} \""
  local message="Checking ${REMOTE_DIR} directory"
  status=$(execSshReturn "$command" "$message")
}

getProjectList(){
  local command="${SSH} \"find public_html -name 'wp-config.php' | grep -o -P '(?<=public_html/).*(?=/wp-config.php)' | sort -u \""
  local message="Get wordpress directories"
  local wp_projects=$(execSshReturn "$command" "$message")
  echo $wp_projects;
}

getDbUser(){
  local project=$1;
  local command="${SSH} \" cat ${REMOTE_DIR}/${project}/${WP_CONFIG} | grep DB_USER | cut -d \' -f 4 \""
  local message=" Getting database user"
  local db_user=$(execSshReturn "$command" "$message")
  echo $db_user
}

getDbPswd(){
  local project=$1;
  local command="${SSH} \" cat ${REMOTE_DIR}/${project}/${WP_CONFIG} | grep DB_PASSWORD | cut -d \' -f 4 \""
  local message=" Getting database password "
  local db_pswd=$(execSshReturn "$command" "$message")
  echo $db_pswd
}

getDbName(){
  local project=$1;
  local command="${SSH} \" cat ${REMOTE_DIR}/${project}/${WP_CONFIG} | grep DB_NAME | cut -d \' -f 4 \""
  local message="Getting database name"
  local db_name=$(execSshReturn "$command" "Getting database name")
  echo $db_name
}

getDbHost(){
  local project=$1;
  local command="${SSH} \" cat ${REMOTE_DIR}/${project}/${WP_CONFIG} | grep DB_HOST | cut -d \' -f 4 \""
  local message="Getting database host"
  local db_host=$(execSshReturn "$command" "$message")
  echo $db_host
}

createDbBackup(){
  local db_user=$1;
  local db_pswd=$2;
  local db_name=$3;
  local db_host=$4;
  local project=$5;
  local backup="${REMOTE_DIR}/${project}/DBbackup.sql"
  local command="${SSH} \"mysqldump -u'${db_user}' -p'${db_pswd}' -h'${db_host}'--single-transaction --compress ${db_name} > ${backup} \""
  local message="Creating database backup"
  execSshAction "$command" "$message"
}

createDbBackupWPCLI(){
  local project=$1;
  local backup="${REMOTE_DIR}/${project}/DBbackup.sql"
  local command="${SSH} \" wp db export $backup --path=${REMOTE_DIR}/${project}\""
  local message="[ Project: $project ] Creating database backup by WP_CLI"
  execSshAction "$command" "$message"
}

downloadProject(){
  local project=$1;
  rsync -e "sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no -p${SSH_PORT} -l ${SSH_USER}" \
    -Sa \
    ${SSH_HOST}:${REMOTE_DIR}/${project}/ /${PROJECT_DIR}/${project}/
}

#validatePublicHtmlDir
#wpProjects=( $(getProjectList) )
#[[ -d ${LOCAL_DIR} ]] && rm -rf ${LOCAL_DIR} || mkdir ${LOCAL_DIR}

#for projectName in ${wpProjects[@]}; do
#  mkdir -p ${LOCAL_DIR}/${projectName}
#  echo "-----------$projectName------"
#  createDbBackupWPCLI $projectName
#  downloadProject $projectName
#  execAction "downloadProject $projectName" "[ Project: $projectName ] Downloading project"
#  dbUser=$(getDbUser $projectName)
#  dbPswd=$(getDbPswd $projectName)
#  dbName=$(getDbName $projectName)
#  dbHost=$(getDbHost $projectName)
#  echo ----- $dbUser  $dbPswd  $dbName $dbHost
#  createDbBackup $dbUser $dbPswd $dbName $dbHost $projectName
#done

#echo ------- $wpProjects
#db_name=$(getDbName)

getSSHprojects(){
  for i in "$@"; do
    case $i in
      --ssh-user=*)
      SSH_USER=${i#*=}
      shift
      shift
      ;;
      --ssh-password=*)
      SSH_PASSWORD=${i#*=}
      shift
      shift
      ;;
      --ssh-port=*)
      SSH_PORT=${i#*=}
      shift
      shift
      ;;
      --ssh-host=*)
      SSH_HOST=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done



  SSH="timeout 300 sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST} -p${SSH_PORT}"
  validatePublicHtmlDir
  wpProjects=( $(getProjectList) )
  [[ -d ${PROJECT_DIR} ]] && rm -rf ${PROJECT_DIR} || mkdir ${PROJECT_DIR}

  for projectName in ${wpProjects[@]}; do
    mkdir -p ${PROJECT_DIR}/${projectName}
    echo "-----------$projectName------"
  done
}

case ${1} in
    getSSHprojects)
        getSSHprojects "$@"
        ;;

    getGITproject)
        getGITproject "$@"
        ;;

esac
