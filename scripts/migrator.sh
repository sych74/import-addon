#!/bin/bash

SUCCESS_CODE=0
FAIL_CODE=99
AUTHORIZATION_ERROR_CODE=701
WP_TOOLKIT_ERROR_CODE=702
BASE_DIR="$HOME/migrator"
RUN_LOG="/var/log/migrator.log"
BACKUP_DIR="${BASE_DIR}/backup"
DB_BACKUP="db_backup.sql"
WEBROOT_DIR="/var/www/webroot/ROOT"
WP_CONFIG="${WEBROOT_DIR}/wp-config.php"
WP_ENV="${BASE_DIR}/.wpenv"
WP_PROJECTS="projects.json"
WP_CLI="${BASE_DIR}/wp"
REMOTE_WP_CLI_DIR="jelastic/wp-cli"

trap "execResponse '${FAIL_CODE}' 'Please check the ${RUN_LOG} log file for details.'; exit 0" TERM
export TOP_PID=$$

[[ -d ${BACKUP_DIR} ]] && mkdir -p ${BACKUP_DIR}
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

getRemoteWP_CLI(){
  local remote_wp_cli_dir="jelastic/wp-cli"
  local get_remote_wp_cli="${SSH} \"command -v wp > /dev/null && {  echo 'true'; } || { echo 'false'; }\""
  local result=$(execSshReturn "${get_remote_wp_cli}" "Validate default WP-CLI on remote host")
  if [[ "x${result}" == "xtrue" ]]; then
    log "Using default WP-CLI installation";
    local wp_cli="wp"
  else
    log "Default WP-CLI installation does not found. Installing custom WP-CLI to ${remote_wp_cli_dir} directory";
    local create_remote_dir="${SSH} \"[[ ! -d ${remote_wp_cli_dir} ]] && mkdir -p ${remote_wp_cli_dir} \""
    local install_wp_cli="${SSH} \"curl -s -o ${remote_wp_cli_dir}/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar  && chmod +x ${remote_wp_cli_dir}/wp; \""
    execSshAction "${create_remote_dir}" "Creating directory ${remote_wp_cli_dir} for WP-CLI on remote host"
    execSshAction "${install_wp_cli}" "Installing custom WP-CLI to ${remote_wp_cli_dir} directory"
    local wp_cli="${remote_wp_cli_dir}/wp"
  fi
  local validate_remote_wp_cli="${SSH} \"${wp_cli} --info 2>&1;\""
  execSshAction "${validate_remote_wp_cli}" "Validating WP-CLI om remote host"
  echo ${wp_cli}
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

validateWPtoolkit(){
  local command="${SSH} \"command -v wp-toolkit\""
  local message="Checking WP Toolkit on remote host"
  action_to_base64=$(echo $command|base64 -w 0)
  stdout=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { log "${message}...done"; } || {
    log "${message}...failed\n${stdout}\n";
    local output_json="{\"result\": ${WP_TOOLKIT_ERROR_CODE}, \"out\": \"${message}...failed\"}"
    echo $output_json
    exit 0
  }
}

getRemoteProjectList(){
  source ${WP_ENV}
  local generateProjectlist="${SSH} \" wp-toolkit --list -format json > ${WP_PROJECTS} \""
  local getProjectlist="sshpass -p ${SSH_PASSWORD} scp -P ${SSH_PORT} ${SSH_USER}@${SSH_HOST}:${WP_PROJECTS} ${BASE_DIR}/${WP_PROJECTS}"
  local validateProjectlist="json_verify < ${BASE_DIR}/${WP_PROJECTS}"
  execSshAction "${generateProjectlist}" "Generate projects list on remote host by wp-toolkit"
  execAction "${getProjectlist}" "Get projects list to local host"
#  execAction "${validateProjectlist}" "Validate JSON format forprojects list ${BASE_DIR}/${WP_PROJECTS}"
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
  rm -rf $dst/{*,.*}; rsync -Sa --no-p --no-g --omit-dir-times --progress $src/ $dst/;
}

syncDB(){
  local backup=$1
  source ${WP_ENV}
  mysql -u${DB_USER} -p${DB_PASSWORD} -h${DB_HOST} ${DB_NAME} < $backup
}


getWPconfigVariable(){
  local var=$1
  local message="Getting $var from ${WP_CONFIG}"
  local command="${WP_CLI} config get ${var} --config-file=${WP_CONFIG} --quiet --path=${WEBROOT_DIR}"
  local result=$(execReturn "${command}" "${message}")
  echo $result
}

setWPconfigVariable(){
  local var=$1
  local value=$2
  local message="Updating $var in the ${WP_CONFIG}"
  local command="${WP_CLI} config set ${var} ${value} --config-file=${WP_CONFIG} --quiet --path=${WEBROOT_DIR}"
  execAction "${command}" "${message}"
}

getSiteUrl(){
  local message="Getting WordPress Site URL"
  local command="${WP_CLI} option get siteurl --path=${WEBROOT_DIR} --quiet --path=${WEBROOT_DIR}"
  local result=$(execReturn "${command}" "${message}")
  echo $result
}

updateSiteUrl(){
  local site_url=$1
  local message="Updating WordPress Site URL to ${site_url}"
  local command="${WP_CLI} option update siteurl ${site_url} --path=${WEBROOT_DIR} --quiet --path=${WEBROOT_DIR}"
  execAction "${command}" "${message}"
}

updateHomeUrl(){
  local home_url=$1
  local message="Updating WordPress Home to ${home_url}"
  local command="${WP_CLI} option update home ${home_url} --path=${WEBROOT_DIR} --quiet --path=${WEBROOT_DIR}"
  execAction "${command}" "${message}"
}

flushCache(){
  local message="Flushing caches"
  local command="${WP_CLI} cache flush --path=${WEBROOT_DIR} --quiet --path=${WEBROOT_DIR}"
  execAction "${command}" "${message}"
}


restoreWPconfig(){
  local message="Restoring ${WP_CONFIG}"
  local command="[ -f ${BASE_DIR}/wp-config.php ] && cat ${BASE_DIR}/wp-config.php > ${WP_CONFIG}"
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

  ### Restore original wp-config.php
  [ -f ${BASE_DIR}/wp-config.php ] && cat ${BASE_DIR}/wp-config.php > ${WP_CONFIG}

  ### Delete custom define wp-jelastic.php
  sed -i '/wp-jelastic.php/d' ${WP_CONFIG}

  createRemoteDbBackup $PROJECT_NAME
  execAction "downloadProject $PROJECT_NAME" "Downloading $PROJECT_NAME project from remote host to ${BACKUP_DIR}"
  addVariable DB_USER $(getWPconfigVariable DB_USER)
  addVariable DB_PASSWORD $(getWPconfigVariable DB_PASSWORD)
  addVariable DB_NAME $(getWPconfigVariable DB_NAME)
  addVariable DB_HOST $(getWPconfigVariable DB_HOST)
  addVariable SITE_URL $(getSiteUrl)
  execAction "syncContent ${BACKUP_DIR} ${WEBROOT_DIR}" "Sync content from ${BACKUP_DIR} to ${WEBROOT_DIR}"
  execAction "syncDB ${BACKUP_DIR}/${DB_BACKUP}" "Sync database from ${BACKUP_DIR}/${DB_BACKUP} "
  source ${WP_ENV}
  setWPconfigVariable DB_USER ${DB_USER}
  setWPconfigVariable DB_PASSWORD ${DB_PASSWORD}
  setWPconfigVariable DB_HOST ${DB_HOST}
  setWPconfigVariable DB_NAME ${DB_NAME}
  setWPconfigVariable WP_DEBUG "false"
  updateSiteUrl $SITE_URL
  updateHomeUrl $SITE_URL
  flushCache
  echo "{\"result\": 0}"
}

getProjectList(){
  local project_list=$(cat ${BASE_DIR}/${WP_PROJECTS});
  local output_json="{\"result\": 0, \"projects\": ${project_list}}"
  echo $output_json
}

checkSSHconnection(){
  local command="${SSH} \"exit 0\""
  local message="Checking SSH connection to remote host"
  action_to_base64=$(echo $command|base64 -w 0)
  stdout=$( { sh -c "$(echo ${action_to_base64}|base64 -d)"; } 2>&1 ) && { log "${message}...done"; } || {
    log "${message}...failed\n${stdout}\n";
    local output_json="{\"result\": ${AUTHORIZATION_ERROR_CODE}, \"out\": \"${message}...failed\"}"
    echo $output_json
    exit 0
  }
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
  checkSSHconnection
  validateWPtoolkit
  REMOTE_WP_CLI=$(getRemoteWP_CLI)
  getRemoteProjectList
  getProjectList
}

### Backuping wp-config.php to /tmp/migrator/ dir
[ ! -f ${BASE_DIR}/wp-config.php \] && cp ${WP_CONFIG} ${BASE_DIR}

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
