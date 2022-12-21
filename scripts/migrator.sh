#!/bin/bash

SUCCESS_CODE=0
FAIL_CODE=99
RUN_LOG="/home/jelastic/migrator/migrator.log"
REMOTE_DIR="public_html"
BASE_DIR="/home/jelastic/migrator"
BACKUP_DIR="${BASE_DIR}/backup"
DB_BACKUP="db_backup.sql"
PROJECT_DIR="${BASE_DIR}/project"
WEBROOT_DIR="/var/www/webroot/ROOT"
WP_CONFIG="${WEBROOT_DIR}/wp-config.php"
WP_ENV="${BASE_DIR}/.wpenv"
WP_CLI="${BASE_DIR}/wp"

trap "execResponse '${FAIL_CODE}' 'Please check the ${RUN_LOG} log file for details.'; exit 1" TERM
export TOP_PID=$$

[[ -d ${BACKUP_DIR} ]] && mkdir -p ${BACKUP_DIR}
[[ -d ${PROJECT_DIR} ]] && mkdir -p ${PROJECT_DIR}
[[ ! -f ${WP_ENV} ]] && touch ${WP_ENV}

log(){
  local message=$1
  local timestamp
  timestamp=`date "+%Y-%m-%d %H:%M:%S"`
  echo -e "[${timestamp}]: ${message}" >> ${RUN_LOG}
}

installWP_CLI(){
  curl -s -o ${WP_CLI} https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar  && chmod +x ${WP_CLI};
  echo "apache_modules:" > ${BASE_DIR}/wp-cli.yml;
  echo "  - mod_rewrite" >> ${BASE_DIR}/wp-cli.yml;
  ${WP_CLI} --info 2>&1;
}

execResponse(){
  local result=$1
  local message=$2
  local output_json="{\"result\": ${result}, \"out\": \"${message}\"}"
  echo $output_json
}

execAction(){
  local action="$1"
  local message="$2"
  stdout=$( { ${action}; } 2>&1 ) && { log "${message}...done";  } || {
    log "${message}...failed\n${stdout}\n";
    kill -s TERM $TOP_PID;
  }
}

execReturn(){
  local action="$1"
  local message="$2"
  stdout=$( { ${action}; } 2>&1 ) && { echo ${stdout}; log "${message}...done";  } || {
    log "${message}...failed\n${stdout}\n";
    kill -s TERM $TOP_PID;
  }
}

execSshAction(){
  local action="$1"
  local message="$2"
  action_to_base64=$(echo $action|base64 -w 0)
  stderr=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { log "${message}...done"; } || {
    log "${message}...failed\n${stdout}\n";
    kill -s TERM $TOP_PID;
  }
}

execSshReturn(){
  local action="$1"
  local message="$2"
  local result=${FAIL_CODE}
  action_to_base64=$(echo $action|base64 -w 0)
  stdout=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { echo ${stdout}; log "${message}...done"; } || {
    log "${message}...failed\n${stdout}\n";
    kill -s TERM $TOP_PID;
  }
}

validatePublicHtmlDir(){
  local command="${SSH} \"[[ -d ${REMOTE_DIR} ]] && {  echo 'true'; } || { echo 'false'; } \""
  local message="Checking ${REMOTE_DIR} directory"
  result=$(execSshReturn "$command" "$message")
}

getRemoteProjectList(){
  local command="${SSH} \"find public_html -name 'wp-config.php' | grep -o -P '(?<=public_html/).*(?=/wp-config.php)' | sort -u \""
  local message="Get wordpress directories"
  local remote_projects=$(execSshReturn "$command" "$message")
  echo $remote_projects
}

addVariable(){
  local var=$1
  local value=$2
  grep -q $var $WP_ENV || { echo "${var}=${value}" >> $WP_ENV; }
}

updateVariable(){
  local var=$1
  local value=$2
  grep -q $var $WP_ENV && { sed -i "s/${var}.*/${var}=${value}/" $WP_ENV; } || { echo "${var}=${value}" >> $WP_ENV; }
}

createRemoteDbBackup(){
  local project=$1;
  local db_backup="${REMOTE_DIR}/${project}/${DB_BACKUP}"
  local command="${SSH} \" wp db export $db_backup --path=${REMOTE_DIR}/${project}\""
  local message="Creating database backup by WP_CLI on remote host"
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
  mysql -u${DB_USER} -p${DB_PASSWORD} -h${DB_HOST} ${DB_NAME} < $backup
}


getWPconfigVariable(){
  local var=$1
  local message="Getting $var from ${WP_CONFIG}"
  local command="${WP_CLI} config get ${var} --config-file=${WP_CONFIG} --quiet"
  local result=$(execReturn "${command}" "${message}")
  echo $result
}

setWPconfigVariable(){
  local var=$1
  local value=$2
  local message="Updating $var in the ${WP_CONFIG}"
  local command="${WP_CLI} config set ${var} ${value} --config-file=${WP_CONFIG} --quiet"
  execAction "${command}" "${message}"
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
  createDbBackup $PROJECT_NAME
  downloadProject $PROJECT_NAME
  addVariable DB_USER $(getWPconfigVariable DB_PASSWORD)
  addVariable DB_PASSWORD $(getWPconfigVariable DB_PASSWORD)
  addVariable DB_NAME $(getWPconfigVariable DB_NAME)
  addVariable DB_HOST $(getWPconfigVariable DB_HOST)
  execAction "syncContent ${BACKUP_DIR} ${WEBROOT_DIR}" "Sync content from ${BACKUP_DIR} to ${WEBROOT_DIR}"
  execAction "syncDB ${BACKUP_DIR}/${DB_BACKUP}" "Sync database from ${BACKUP_DIR}/${DB_BACKUP} "
  source ${WP_ENV}
  setWPconfigVariable DB_USER ${DB_USER}
  setWPconfigVariable DB_PASSWORD ${DB_PASSWORD}
  setWPconfigVariable DB_HOST ${DB_HOST}
  setWPconfigVariable DB_NAME ${DB_NAME}
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

  updateVariable SSH_USER ${SSH_USER}
  updateVariable SSH_PASSWORD ${SSH_PASSWORD}
  updateVariable SSH_PORT ${SSH_PORT}
  updateVariable SSH_HOST ${SSH_HOST}
  source ${WP_ENV}
  SSH="timeout 300 sshpass -p ${SSH_PASSWORD} ssh -T -o StrictHostKeyChecking=no ${SSH_USER}@${SSH_HOST} -p${SSH_PORT}"
  validatePublicHtmlDir
  wpProjects=( $(getRemoteProjectList) )

  [[ -d ${PROJECT_DIR} ]] && rm -rf ${PROJECT_DIR} || mkdir -p ${PROJECT_DIR}
  for projectName in ${wpProjects[@]}; do mkdir -p ${PROJECT_DIR}/${projectName}; done
  getProjectList
}

execAction "installWP_CLI" 'Install WP-CLI'

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
