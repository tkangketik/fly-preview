#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_NAME=$(echo $GITHUB_REPOSITORY | tr "/" "-")

EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_name}
APP=$(echo "${INPUT_NAME:-pr-$PR_NUMBER-$REPO_NAME}" | tr '_' '-')
APP_DB="$APP-db"
REGION="${INPUT_REGION:-${FLY_REGION:-iad}}"
ORG="${INPUT_ORG:-${FLY_ORG:-personal}}"
IMAGE="$INPUT_IMAGE"
CONFIG="${INPUT_CONFIG:-fly.toml}"
VM="${INPUT_VM:-shared-cpu-1x}"
VM_MEMORY="${INPUT_VM_MEMORY:-256}"

# replace any dash with underscore in app name
# fly.io does not accept dashes in volume names
VOLUME=$(echo $APP | tr '-' '_')

if ! echo "$APP" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  # destroy app DB
  if flyctl status --app "$APP_DB"; then
    flyctl apps destroy "$APP_DB" -y || true
  fi

  # destroy associated volumes as well
  # @TODO: refactor code below to avoid repeatedly running `flyctl volumes list ...`
  # we could declare the variable in line 49 outside the if block, then reuse it inside the block,
  # but in the case where VOLUME_ID is an empty string (no volume), GitHub action runner throws an error
  if flyctl volumes list --app "$APP" | grep -oh "\w*vol_\w*"; then
    VOLUME_ID=$(flyctl volumes list --app "$APP" | grep -oh "\w*vol_\w*")
    flyctl volumes destroy "$VOLUME_ID" -y || true
  fi

  # finally, destroy the app
  if flyctl status --app "$APP"; then
    flyctl apps destroy "$APP" -y || true
  fi
  exit 0
fi

# Check if app exists,
# if not, launch it, but don't deploy yet
if ! flyctl status --app "$APP"; then
  flyctl apps create "$APP" --org "$ORG"
  flyctl regions set "$REGION" --app "$APP" -y
  flyctl scale vm "$VM" --memory "$VM_MEMORY" --app "$APP"

  # look for "migrate" file in the app files
  # if it exists, the app probably needs DB.
  if [ -e "rel/overlays/bin/migrate" ]; then
    # only create db if the app lauched successfully
    if flyctl status --app "$APP"; then
      if flyctl status --app "$APP_DB"; then
        echo "$APP_DB DB already exists"
      else
        flyctl postgres create --name "$APP_DB" --org "$ORG" --region "$REGION" --vm-size shared-cpu-1x --initial-cluster-size 1 --volume-size 1
      fi
      # attaching db to the app if it was created successfully
      if flyctl postgres attach "$APP_DB" --app "$APP" -y; then
        echo "$APP_DB DB attached to $APP"
      else
        echo "Error attaching $APP_DB to $APP, attachments exist"
      fi
    fi
  fi
fi

# find a way to determine if the app requires volumes
# basically, scan the config file if it contains "[mounts]", then create a volume for it
if grep -q "\[mounts\]" "$CONFIG"; then
  # create volume only if none exists
  if ! flyctl volumes list --app "$APP" | grep -oh "\w*vol_\w*"; then
    flyctl volumes create "$VOLUME" --app "$APP" --region "$REGION" --size 1 -y
  fi
  # modify config file to have the volume name specified above.
  sed -i -e 's/source =.*/source = '\"$VOLUME\"'/' "$CONFIG"
fi

# Import any required secrets
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$APP"
fi

# Deploy the app.
flyctl deploy --config "$CONFIG" --app "$APP" --region "$REGION" --remote-only --strategy immediate

# Make some info available to the GitHub workflow.
flyctl status --app "$APP" --json >status.json
HOSTNAME=$(jq -r .Hostname status.json)
APPID=$(jq -r .ID status.json)
MACHINE_STATE=$(jq -r '.Machines[].state' status.json)
echo "hostname=$HOSTNAME" >>$GITHUB_OUTPUT
echo "url=https://$HOSTNAME" >>$GITHUB_OUTPUT
echo "id=$APPID" >>$GITHUB_OUTPUT
echo "name=$APP" >>$GITHUB_OUTPUT
echo "machine_state=$MACHINE_STATE" >>$GITHUB_OUTPUT

# Wait for machine state to be "started"
while [[ "$MACHINE_STATE" != "started" ]]; do
    echo "Waiting for machine state to be 'started'..."
    sleep 10
    flyctl status --app "$APP" --json >status.json
    MACHINE_STATE=$(jq -r '.Machines[].state' status.json)
done

# Finalizing
fly ssh console -C 'bash -c "cd /var/www/html && mkdir -p storage/logs && mkdir -p storage/app/public && mkdir -p storage/debugbar && mkdir -p storage/framework/cache/data && mkdir -p storage/framework/sessions && mkdir -p storage/framework/testing && mkdir -p storage/framework/views && chmod 777 -R /var/www/html/storage/*"' --config "$CONFIG" --app "$APP"
