#!/usr/bin/env bash

# Oracle Enterprise Manager Notification Script in Bash
# Author: Benjamin Buechele
# Company: ITUNIFIED
# GitHub: https://github.com/itunified-io/OEMNotifications

# Determine the script directory
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Change to the script directory
cd "$SCRIPT_DIR" || {
    echo "Failed to change to script directory: $SCRIPT_DIR"
    exit 1
}

# Define log file location relative to script directory
LOG_FILE="logs/oem_notification.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" | tee -a "$LOG_FILE"
}

# Load the INI parser
parse_ini() {
    local ini_file="$1"
    local section=""
    while IFS= read -r line || [[ -n $line ]]; do
        # Remove comments and whitespace
        line="${line%%;*}" # Remove comments starting with ;
        line="${line%%#*}" # Remove comments starting with #
        line="${line//[$'\t\r\n']}" # Trim tabs and newlines
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" # Trim leading/trailing spaces

        # Handle section headers
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^([^=]+)=(.*)$ ]]; then
            # Handle key-value pairs
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            key="${key//./_}" # Replace dots with underscores
            key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" # Trim key spaces
            value="${value%\"}" # Remove trailing quotes
            value="${value#\"}" # Remove leading quotes
            value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" # Trim value spaces

            if [[ -n $section ]]; then
                # Safely declare variables
                eval "CONFIG_${section}_${key}=\"${value}\""
            fi
        fi
    done < "$ini_file"
}

# Function to send an email
send_email() {
    local recipients="$1"
    local subject="$2"
    local body="$3"
    local priority="$4"

    if [[ "${CONFIG_SENDMAIL_enable,,}" == "false" ]]; then
        log "INFO" "Email sending is disabled (SENDMAIL_enable=false). Skipping email to: $recipients"
        return 0
    fi

    # Ensure SMTP server settings are available
    local smtp_server="${CONFIG_SMTP_server}"
    local smtp_port="${CONFIG_SMTP_port}"
    local smtp_sender="${CONFIG_SMTP_sender}"

    if [[ -z "$smtp_server" || -z "$smtp_port" || -z "$smtp_sender" ]]; then
        log "ERROR" "SMTP configuration is missing or incomplete. Please check the [SMTP] section in your configuration file."
        return 1
    fi

    # Set the X-Priority value for the specified priority level
    local x_priority="3"  # Default to Normal
    if [[ "$priority" == "1" ]]; then
        x_priority="1"  # High Priority
    elif [[ "$priority" == "5" ]]; then
        x_priority="5"  # Low Priority
    fi

    # Prepare the email headers and body
    log "INFO" "Sending email to: $recipients with priority $priority (X-Priority: $x_priority)"

    SUB="\nX-Priority: $x_priority"
    SUB1="$(echo -e $subject $SUB)"
    log "DEBUG" "Subject: $SUB1"

    # Split the recipients by semicolon and pass them as individual arguments to mailx
    log "DEBUG" "recipients: $recipients"
    # Split the recipients by semicolon and create a comma-separated string
    RECIPIENT_LIST=$(echo "$recipients" | tr ';' ',')

    # Send the email using mailx
    printf "%b" "$body" | mailx -S smtp="$smtp_server:$smtp_port" -S from="$smtp_sender" -s "$SUB1" $RECIPIENT_LIST

    if [[ $? -eq 0 ]]; then
        log "INFO" "Email successfully sent to: $recipients"
        return 0
    else
        log "ERROR" "Failed to send email to: $recipients"
        return 1
    fi
}

# Read the configuration file
CONFIG_FILE="config/configurations.ini"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR" "Configuration file not found: $CONFIG_FILE"
    exit 1
fi
log "INFO" "Parsing configuration file: $CONFIG_FILE"
parse_ini "$CONFIG_FILE"

# Extract event details from environment variables
EVENT_NAME="${EVENT_NAME:-Unknown Event}"
SEVERITY="${SEVERITY:-Unknown Severity}"
TARGET_NAME="${TARGET_NAME:-Unknown Target}"
TARGET_TYPE="${TARGET_TYPE:-Unknown Type}"
TARGET_LIFECYCLE_STATUS="${TARGET_LIFECYCLE_STATUS:-Unknown Status}"
MESSAGE="${MESSAGE:-No details provided.}"

# Debugging: Log extracted environment variables
if [[ "${CONFIG_DEBUG_debug,,}" == "true" ]]; then
    log "DEBUG" "Event Details:"
    log "DEBUG" "  EVENT_NAME: $EVENT_NAME"
    log "DEBUG" "  SEVERITY: $SEVERITY"
    log "DEBUG" "  TARGET_NAME: $TARGET_NAME"
    log "DEBUG" "  TARGET_TYPE: $TARGET_TYPE"
    log "DEBUG" "  TARGET_LIFECYCLE_STATUS: $TARGET_LIFECYCLE_STATUS"
    log "DEBUG" "  MESSAGE: $MESSAGE"
fi

# Apply rules
log "INFO" "Applying notification rules..."
EMAIL_SENT=false
RULE_MATCHED=false

for i in $(seq 1 10); do
    rule_condition_target_name="CONFIG_RULES_rule${i}_condition_target_name"
    rule_condition_target_type="CONFIG_RULES_rule${i}_condition_target_type"
    rule_condition_lifecycle_status="CONFIG_RULES_rule${i}_condition_lifecycle_status"
    rule_action_recipients="CONFIG_RULES_rule${i}_action_recipients"
    rule_action_priority="CONFIG_RULES_rule${i}_action_priority"

    if [ -z "${!rule_action_recipients}" ]; then
        log "DEBUG" "Rule ${i} skipped: action recipients are undefined."
        continue # Skip empty rules and proceed to the next
    fi

    log "DEBUG" "Evaluating Rule ${i}:"
    log "DEBUG" "  Condition - target_name: '${!rule_condition_target_name}', target_type: '${!rule_condition_target_type}', lifecycle_status: '${!rule_condition_lifecycle_status}'"
    log "DEBUG" "  Action - recipients: '${!rule_action_recipients}', priority: '${!rule_action_priority}'"

    # Treat empty or "all" as wildcard matches
    match_target_name=false
    match_target_type=false
    match_lifecycle_status=false

    # Compare target_name
    if [[ -z "${!rule_condition_target_name}" || "${!rule_condition_target_name}" == "all" || "${!rule_condition_target_name}" == "$TARGET_NAME" ]]; then
        match_target_name=true
    else
        log "DEBUG" "Rule ${i}: target_name mismatch - expected: '${!rule_condition_target_name}', found: '$TARGET_NAME'"
    fi

    # Compare target_type
    if [[ -z "${!rule_condition_target_type}" || "${!rule_condition_target_type}" == "all" || "${!rule_condition_target_type}" == "$TARGET_TYPE" ]]; then
        match_target_type=true
    else
        log "DEBUG" "Rule ${i}: target_type mismatch - expected: '${!rule_condition_target_type}', found: '$TARGET_TYPE'"
    fi

    # Case-insensitive comparison for lifecycle_status
    if [[ -z "${!rule_condition_lifecycle_status}" || "${!rule_condition_lifecycle_status,,}" == "all" || "${!rule_condition_lifecycle_status,,}" == "${TARGET_LIFECYCLE_STATUS,,}" ]]; then
        match_lifecycle_status=true
    else
        log "DEBUG" "Rule ${i}: lifecycle_status mismatch - expected: '${!rule_condition_lifecycle_status}', found: '$TARGET_LIFECYCLE_STATUS'"
    fi

    # If all conditions match, send the email
    if $match_target_name && $match_target_type && $match_lifecycle_status; then
        RULE_MATCHED=true
        log "INFO" "Rule matched: rule${i}"

        # Prepare email content
        subject="OEM Alert: $EVENT_NAME - $SEVERITY on $TARGET_NAME ($TARGET_LIFECYCLE_STATUS)"
        body="Oracle Enterprise Manager Event Notification\n\nEvent Name: $EVENT_NAME\nEvent Type: $SEVERITY\nTarget: $TARGET_NAME\nTarget Type: $TARGET_TYPE\nLifecycle Status: $TARGET_LIFECYCLE_STATUS\n\nDetails:\n$MESSAGE\n\nPlease address this issue promptly."

        if send_email "${!rule_action_recipients}" "$subject" "$body" "${!rule_action_priority}"; then
            EMAIL_SENT=true
        fi

        # Break on first match if evaluation_mode is `first_match`
        if [[ "${CONFIG_RULES_evaluation_mode,,}" == "first_match" ]]; then
            log "INFO" "Evaluation mode is first_match. Stopping after rule${i}."
            break
        fi
    fi
done

if [[ "$RULE_MATCHED" == false ]]; then
    log "WARNING" "No rules matched for the event. Check your configurations and rules."
fi

if [[ "$EMAIL_SENT" == false ]]; then
    log "INFO" "No email was sent. Email sending is either disabled or no rules matched."
fi

