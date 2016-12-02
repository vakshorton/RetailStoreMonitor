#!/bin/bash

export NIFI_HOST=$1
export NIFI_PORT=$2
export ATLAS_HOST=$3
export ATLAS_PORT=$4
export HIVESERVER_HOST=$5
export HIVESERVER_PORT=$6

retargetNifiFlowReporter() {
	sleep 1
	echo "*********************************Getting Nifi Reporting Task Id..."
	REPORTING_TASK_ID=$(curl -H "Content-Type: application/json" -X GET http://$NIFI_HOST:$NIFI_PORT/nifi-api/flow/reporting-tasks| grep -Po '("component":{"id":"[0-9a-zA-z\-]+","name":"AtlasFlowReportingTask)'| grep -Po 'id":"([0-9a-zA-z\-]+)'| grep -Po ':"([0-9a-zA-z\-]+)'| grep -Po '([0-9a-zA-z\-]+)')

	echo "*********************************Getting Nifi Reporting Task Revision..."
	REPORTING_TASK_REVISION=$(curl -X GET http://$NIFI_HOST:$NIFI_PORT/nifi-api/reporting-tasks/$REPORTING_TASK_ID |grep -Po '\"version\":([0-9]+)'|grep -Po '([0-9]+)')

	echo "*********************************Stopping Nifi Reporting Task..."
	PAYLOAD=$(echo "{\"id\":\"$REPORTING_TASK_ID\",\"revision\":{\"version\":$REPORTING_TASK_REVISION},\"component\":{\"id\":\"$REPORTING_TASK_ID\",\"state\":\"STOPPED\"}}")

	curl -d "$PAYLOAD" -H "Content-Type: application/json" -X PUT http://$NIFI_HOST:$NIFI_PORT/nifi-api/reporting-tasks/$REPORTING_TASK_ID

	echo "*********************************Getting Nifi Reporting Task Revision..."
	REPORTING_TASK_REVISION=$(curl -X GET http://$NIFI_HOST:$NIFI_PORT/nifi-api/reporting-tasks/$REPORTING_TASK_ID |grep -Po '\"version\":([0-9]+)'|grep -Po '([0-9]+)')

	echo "*********************************Removing Nifi Reporting Task..."
	curl -X DELETE http://$NIFI_HOST:$NIFI_PORT/nifi-api/reporting-tasks/$REPORTING_TASK_ID?version=$REPORTING_TASK_REVISION

	echo "*********************************Instantiating Reporting Task..."
	PAYLOAD=$(echo "{\"revision\":{\"version\":0},\"component\":{\"name\":\"AtlasFlowReportingTask\",\"type\":\"org.apache.nifi.atlas.reporting.AtlasFlowReportingTask\",\"properties\":{\"Atlas URL\":\"http://$ATLAS_HOST:$ATLAS_PORT\",\"Nifi URL\":\"http://$NIFI_HOST:$NIFI_PORT\"}}}")

	REPORTING_TASK_ID=$(curl -d "$PAYLOAD" -H "Content-Type: application/json" -X POST http://$NIFI_HOST:$NIFI_PORT/nifi-api/controller/reporting-tasks|grep -Po '("component":{"id":")([0-9a-zA-z\-]+)'| grep -Po '(:"[0-9a-zA-z\-]+)'| grep -Po '([0-9a-zA-z\-]+)')

	echo "*********************************Starting Reporting Task..."
PAYLOAD=$(echo "{\"id\":\"$REPORTING_TASK_ID\",\"revision\":{\"version\":1},\"component\":{\"id\":\"$REPORTING_TASK_ID\",\"state\":\"RUNNING\"}}")

	curl -d "$PAYLOAD" -H "Content-Type: application/json" -X PUT http://$NIFI_HOST:$NIFI_PORT/nifi-api/reporting-tasks/$REPORTING_TASK_ID
	sleep 1
}

recreateRetailTransactionHistoryTable () {
	HIVESERVER_HOST=$(getHiveServerHost)

	HQL="DROP TABLE retail_transaction_history;"
	# CREATE Customer Transaction History Table
	beeline -u jdbc:hive2://$HIVESERVER_HOST:HIVESERVER_PORT/default -d org.apache.hive.jdbc.HiveDriver -e "$HQL"
	
	HQL="CREATE TABLE IF NOT EXISTS retail_transaction_history (transactionId String,
	    			locationId String,
	    			item String,
	    			accountNumber String,
	    			amount Double,
	    			currency String,
	    			isCardPresent String,
	    			ipAddress String,
	    			transactionTimeStamp String)
	COMMENT 'Retail Purchase Transaction History'
	PARTITIONED BY (accountType String, shipToState String)
	CLUSTERED BY (accountNumber) INTO 30 BUCKETS
	STORED AS ORC;"
	
	# CREATE Customer Transaction History Table
	beeline -u jdbc:hive2://$HIVESERVER_HOST:HIVESERVER_PORT/default -d org.apache.hive.jdbc.HiveDriver -e "$HQL"
}

echo "*********************************Setting Environment..."
. ~/.bash_profile
env

#cd $ROOT_PATH/DataPlaneUtils
#mvn clean package
#java -jar target/DataPlaneUtils-0.0.1-SNAPSHOT-jar-with-dependencies.jar

# Recreate TransactionHistory table to reset Atlas qualified name to this cluster
echo "*********************************Recreating TransactionHistory Table..."
recreateRetailTransactionHistoryTable

# Redeploy Storm Topology to send topology meta data to Atlas
echo "*********************************Redeploy Storm Topology..."
storm kill RetailTransactionMonitor
storm jar /home/storm/RetailTransactionMonitor-0.0.1-SNAPSHOT.jar com.hortonworks.iot.retail.topology.RetailTransactionMonitorTopology

# Start Nifi Flow Reporter to send flow meta data to Atlas
echo "*********************************Retargeting Nifi Flow Reporting Task..."
sleep 5
retargetNifiFlowReporter

exit 0