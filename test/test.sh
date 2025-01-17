export EVENT_NAME="Critical Disk Failure"
export SEVERITY="CRITICAL"
export TARGET_NAME="dbserver01"
export TARGET_TYPE="database"
export TARGET_LIFECYCLE_STATUS="Mission Critical"
export MESSAGE="Disk usage exceeded 90%"

./OEMNotification.sh
