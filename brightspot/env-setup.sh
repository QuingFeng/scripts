#!/bin/bash

PROJECT="$1"
LDAP_USER="$2"

MYSQL_USER="root"
MYSQL_PASS=""
MYSQL_DB=${PROJECT}
BASE_PROJECT="0"

TOMCAT_PATH="http://archive.apache.org/dist/tomcat/tomcat-8/v8.0.32/bin/"
TOMCAT_DIR="apache-tomcat-8.0.32"
TOMCAT_EXT=".tar.gz"

SOLR_PATH="http://archive.apache.org/dist/lucene/solr/4.8.1/"
SOLR_DIR="solr-4.8.1"
SOLR_EXT=".tgz"

# use psd project repo if it exists, otherwise use the base project
git ls-remote "https://github.com/perfectsense/${PROJECT}.git" > /dev/null 2>&1
if [ "$?" -ne 0 ]; then
    CODE="https://github.com/stephen-lane/base-project.git"
    BASE_PROJECT="1"
else
	CODE="https://github.com/perfectsense/${PROJECT}.git"
fi

command_exists () {
	if [[ "$OSTYPE" == "linux-gnu" ]]; then
        hash "$1" 2>/dev/null || { echo >&2 "Installing $1 ..."; apt-get install "$1"; }
	elif [[ "$OSTYPE" == "darwin"* ]]; then
		# Install brew if its not installed already.
		which -s brew
		if [[ $? != 0 ]] ; then
			echo "Brew not installed, installing..."
			/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
		fi
		hash "$1" 2>/dev/null || { echo >&2 "Installing $1 ..."; brew install "$1"; }
	fi
}

#  Check for required binaries
command_exists "git"
command_exists "wget"
command_exists "maven"

# Create project directory
PROJECT_TOP_LEVEL=`echo $PROJECT | awk '{print toupper($0)}'`
mkdir ${PROJECT_TOP_LEVEL}
cd ${PROJECT_TOP_LEVEL}

echo "Geting and extract server binaries"
wget ${TOMCAT_PATH}${TOMCAT_DIR}${TOMCAT_EXT}
wget ${SOLR_PATH}${SOLR_DIR}${SOLR_EXT}

echo "Extracting server binaries"
tar -xvzf ${TOMCAT_DIR}${TOMCAT_EXT}
tar -xvzf ${SOLR_DIR}${SOLR_EXT}


echo "Setting up solr..."
cp -R "${SOLR_DIR}/example/solr" "${TOMCAT_DIR}/"
cp -rv "${SOLR_DIR}/example/lib/ext/"* "${TOMCAT_DIR}/lib"
cp "${SOLR_DIR}/dist/${SOLR_DIR}.war" "${TOMCAT_DIR}/webapps/solr.war"

echo "Download and install Solr config"
wget https://raw.githubusercontent.com/perfectsense/dari/master/etc/solr/config-5.xml
wget https://raw.githubusercontent.com/perfectsense/dari/master/etc/solr/schema-12.xml
mv config-5.xml "${TOMCAT_DIR}/solr/collection1/conf/solrconfig.xml"
mv schema-12.xml "${TOMCAT_DIR}/solr/collection1/conf/schema.xml"


echo "Get tomcat configs from qa, or use base config if no ldap user supplied ..."
if [ -z "$2" ]; then
    echo "Using bare bones tomcat config.."
    wget https://raw.githubusercontent.com/stephen-lane/scripts/master/brightspot/templates/context.xml
	wget https://raw.githubusercontent.com/stephen-lane/scripts/master/brightspot/templates/server.xml
else
	scp "${LDAP_USER}@qa.${PROJECT}.psdops.com:/servers/${PROJECT}/conf/server.xml" .
	scp "${LDAP_USER}@qa.${PROJECT}.psdops.com:/servers/${PROJECT}/conf/context.xml" .
fi


echo "Setting up tomcat configs to work locally..."
# server.xml customisation
sed -i "" 's|jdbc:mysql://.*:3306|jdbc:mysql://localhost:3306|g' server.xml
sed -i "" 's|${private_ip}||g' server.xml
sed -i "" 's|:3306/.*?|:3306/'$MYSQL_DB'?|g' server.xml
sed -i "" 's/\([[:blank:]]username="\)[^"]*"/\1'$MYSQL_USER'"/' server.xml
sed -i "" 's/\([[:blank:]]password="\)[^"]*"/\1'$MYSQL_PASS'"/' server.xml
# context.xml customisation with sed, bit hacky but its the best that can be done without an xml parser.
sed -i "" 's|solr/readServerUrl".*"http://.*:8180/solr|solr/readServerUrl" override="false" type="java.lang.String" value="http://localhost:8080/solr|g' context.xml
sed -i "" 's|solr/serverUrl".*"http://.*:8180/solr|solr/serverUrl" override="false" type="java.lang.String" value="http://localhost:8080/solr|g' context.xml
sed -i "" 's|dari/recalculationTaskHost".*internal"|dari/recalculationTaskHost" value="0.0.0.0"|g' context.xml

# add dari/storage/local/rootPath value for bare bones install
CUR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -z "$2" ]; then
	sed -i "" 's|{{tomcat_dir}}|${CUR_DIR}/${TOMCAT_DIR}|g' context.xml
	mkdir "${CUR_DIR}/${TOMCAT_DIR}/webapps/storage"
fi

# append solr home element into to context root element
SOLR_HOME="${CUR_DIR}/${TOMCAT_DIR}/solr"
sed -i "" 's|<Context.*>|<Context reloadable="true" allowLinking="true">\
<Environment name="solr/home" override="false" type="java.lang.String" value="'${SOLR_HOME}'"/>|' context.xml

rm -rf "${TOMCAT_DIR}/conf/server.xml"
rm -rf "${TOMCAT_DIR}/conf/context.xml"
mv server.xml "${TOMCAT_DIR}/conf/server.xml"
mv context.xml "${TOMCAT_DIR}/conf/context.xml"


echo "Getting Mysql driver..."
wget "https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.40.tar.gz"
tar -xvzf mysql-connector-java-5.1.40.tar.gz
cp "mysql-connector-java-5.1.40/mysql-connector-java-5.1.40-bin.jar" "${TOMCAT_DIR}/lib"
rm -f mysql-connector-java-5.1.40.tar.gz
rm -rf mysql-connector-java-5.1.40

echo "Create local database"

if [[ "$MYSQL_PASS" -ne "" ]]; then
	echo "CREATE DATABASE IF NOT EXISTS ${MYSQL_DB}" | /usr/local/mysql/bin/mysql "-u$MYSQL_USER" "-p$MYSQL_PASS"
else
	echo "CREATE DATABASE IF NOT EXISTS ${MYSQL_DB}" | /usr/local/mysql/bin/mysql "-u$MYSQL_USER"
fi

git clone "${CODE}"
# if this is a base project then rename with project name
if [ $BASE_PROJECT -eq "1" ]; then
	mv base-project "${PROJECT}"
	sed -i "" 's|<artifactId>base-project</artifactId>|<artifactId>'${PROJECT}'</artifactId>|g' "${PROJECT}/pom.xml"
fi

echo "Build project..."
mvn -f "${PROJECT}/pom.xml" clean install

echo "Link target directory to tomcat.."
target_dir=`find ${PROJECT}/target -type f -name "*.war" | sed -e 's/'${PROJECT}'\/\(.*\).war/\1/'`
rm -rf "${TOMCAT_DIR}/webapps/ROOT"
ln -sf "../../${PROJECT}/${target_dir}" "${TOMCAT_DIR}/webapps/ROOT"

echo "Clean up.."
rm -f ${TOMCAT_DIR}${TOMCAT_EXT}
rm -f ${SOLR_DIR}${SOLR_EXT}

echo "Create new eclipse workspace.."
mkdir Workspace

echo "Start tomcat.."
${TOMCAT_DIR}/bin/startup.sh
less +F ${TOMCAT_DIR}/logs/catalina.out






