#!/usr/bin/env bash

#Validate Sudo
sudo touch /tmp/sudotag
if [ ! -f /tmp/sudotag ]; then
    echo "User cannot sudo. Exit script."
    exit 1
fi

cd /opt/pajbot
sudo systemctl stop 'pajbot-web@*' --all
sudo systemctl stop 'pajbot@*' --all
sudo git pull
sudo chown -R pajbot:pajbot /opt/pajbot
sudo systemctl start 'pajbot@*' --all
sudo systemctl start 'pajbot-web@*' --all
