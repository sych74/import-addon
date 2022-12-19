#!/bin/bash

SUCCESS_CODE=0
FAIL_CODE=99
AUTHORIZATION_ERROR_CODE=701
RUN_LOG="/home/jelastic/migrator/migrator.log"
SSH="timeout 300 sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST} -p${SSH_PORT}"
SSH_CREDS=
REMOTE_DIR="public_html"
BASE_DIR="/home/jelastic/migrator"
BACKUP_DIR="${BASE_DIR}/backup"
DB_BACKUP="db_backup.sql"
PROJECT_DIR="${BASE_DIR}/project"
WEBROOT_DIR="/var/www/webroot/ROOT"
WP_CONFIG="${WEBROOT_DIR}/wp-config.php"
WP_ENV="${BASE_DIR}/.wpenv"

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

execActionReturn(){
  local action="$1"
  local message="$2"
  stderr=$( { ${action}; } 2>&1 ) && { echo ${stdout}; log "${message}...done"; } || {
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

getSshProjectList(){
  local command="${SSH} \"find public_html -name 'wp-config.php' | grep -o -P '(?<=public_html/).*(?=/wp-config.php)' | sort -u \""
  local message="Get wordpress directories"
  local ssh_wp_projects=$(execSshReturn "$command" "$message")
  echo $ssh_wp_projects;
}

getWPconfigVar(){
  local var=$1;
  local message="Getting $var from ${WP_CONFIG}"
  local result=$(cat ${WP_CONFIG} | grep $var | cut -d \' -f 4)
  log "${message}...done";
  echo $result
}

addVar(){
  local var=$1
  local value=$2
  [[ ! -f $WP_ENV ]] && touch $WP_ENV;
  grep -q $var $WP_ENV || { echo "${var}=${value}" >> $WP_ENV; }
}

updateVar(){
  local var=$1
  local value=$2
  [[ ! -f $WP_ENV ]] && touch $WP_ENV;
  grep -q $var $WP_ENV && { sed -i "s/${var}.*/${var}=${value}/" $WP_ENV; } || { echo "${var}=${value}" >> $WP_ENV; }
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
  local db_backup="${REMOTE_DIR}/${project}/${DB_BACKUP}"
  local command="${SSH} \" wp db export $db_backup --path=${REMOTE_DIR}/${project}\""
  local message="[ Project: $project ] Creating database backup by WP_CLI"
  execSshAction "$command" "$message"
}

downloadProject(){
  local project=$1;
  rm -rf ${BACKUP_DIR}; mkdir -p ${BACKUP_DIR};
  rsync -e "sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no -p${SSH_PORT} -l ${SSH_USER}" \
    -Sa \
    ${SSH_HOST}:${REMOTE_DIR}/${project}/ /${BACKUP_DIR}/
}

syncContent(){
  local src=$1
  local dst=$2
  rm -rf $dst/{*,.*}; rsync -Sa --progress $src/ $dst/;
}

syncDB(){
  local backup=$1
  source ${WP_ENV}
  mysql -u${DB_USER} -p${DB_PASS} -h${DB_HOST} ${DB_NAME} < $backup
}

setWPconfigVar(){
  local var=$1;
  local value=$2;
  local message="Setting $var= $value in the ${WP_CONFIG}"
  sed -i "s/^${var}.*/${var}=${value}/" ${WP_CONFIG};
  log "${message}...done";
}

deployProject(){
  for i in "$@"; do
    case $i in
      --project-name=*)
      PROJECT_NAME=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done

  source ${WP_ENV}
  SSH="timeout 300 sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST} -p${SSH_PORT}"
  createDbBackupWPCLI $PROJECT_NAME
  downloadProject $PROJECT_NAME
  addVar DB_USER $(getWPconfigVar DB_USER)
  addVar DB_PASS $(getWPconfigVar DB_PASS)
  addVar DB_NAME $(getWPconfigVar DB_NAME)
  addVar DB_HOST $(getWPconfigVar DB_HOST)
  execAction "syncContent ${BACKUP_DIR} ${WEBROOT_DIR}" "Sync content from ${BACKUP_DIR} to ${WEBROOT_DIR} "
  execAction "syncDB ${BACKUP_DIR}/${DB_BACKUP}" "Sync database from ${BACKUP_DIR}/${DB_BACKUP} "
  source ${WP_ENV}
  setWPconfigVar DB_USER ${DB_USER}
  setWPconfigVar DB_PASS ${DB_PASS}
  setWPconfigVar DB_HOST ${DB_HOST}
  setWPconfigVar DB_NAME ${DB_NAME}
}


getProjectList(){
  local project_list=$(ls -Qm ${PROJECT_DIR});
  local output_json="{\"result\": 0, \"projects\": [${project_list}]}"
  echo $output_json
}

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

  updateVar SSH_USER ${SSH_USER}
  updateVar SSH_PASSWORD ${SSH_PASSWORD}
  updateVar SSH_PORT ${SSH_PORT}
  updateVar SSH_HOST ${SSH_HOST}

  source ${WP_ENV}

  SSH="timeout 300 sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST} -p${SSH_PORT}"
  validatePublicHtmlDir
  wpProjects=( $(getSshProjectList) )


  [[ -d ${PROJECT_DIR} ]] && rm -rf ${PROJECT_DIR} || mkdir -p ${PROJECT_DIR}
  for projectName in ${wpProjects[@]}; do mkdir -p ${PROJECT_DIR}/${projectName}; done
  getProjectList
}

case ${1} in
    getSSHprojects)
        getSSHprojects "$@"
        ;;

    getProjectList)
      getProjectList
      ;;

    getGITproject)
        getGITproject "$@"
        ;;

    deployProject)
      deployProject "$@"
      ;;
esac
