#!/usr/bin/env bash
PB1_BRC_OAUTH="" # Broadcaster OAuth. Leave this empty.
source /etc/os-release

if [ -f $PWD/pb1install.config ]; then
    source $PWD/pb1install.config
    PB1_DB="pb_$PB1_BRC"
else
    echo "Config file missing. Exit."
    exit 1
fi

if [[ -z $PB1_ADM || -z $PB1_BRC || -z $PB1_TIMEZONE || -z $PB1_HOST || -z $PB1_NAME ]]; then
    echo "Some config options are undefined"
    exit 1
fi

if [[ -z $PB1_BOT_CLID || -z $PB1_BOT_CLSEC ]]; then
    echo "No credentials specified."
    exit 1
fi

if [ $ID == "debian" ] && [ $VERSION_ID == "9" ]
then
    echo "Debian 9 detected"
    OS_VER="debian9"
elif [ $ID == "ubuntu" ] && [ $VERSION_ID == "18.04" ]
then
    echo "Ubuntu 18.04 Detected"
    OS_VER="ubuntu1804"
elif [ $ID == "ubuntu" ] && [ $VERSION_ID == "19.04" ]
then
    echo "Ubuntu 19.04 Detected"
    OS_VER="ubuntu1904"
else
    echo "No supported OS detected. Exit script."
    exit 1
fi

if [ "$LOCAL_INSTALL" == "true" ]
then
    echo "Local install enabled."
    PB1_PROTO="http"
    PB1_WS_PROTO="ws"
else
    PB1_PROTO="https"
    PB1_WS_PROTO="wss"
fi

if [ $DEVMODE == "true" ]
then
    echo "Dev mode enabled"
fi

#Validate Sudo
sudo touch /tmp/sudotag
if [ ! -f /tmp/sudotag ]; then
    echo "User cannot sudo. Exit script."
    exit 1
fi


#Create pajbot user
sudo adduser --shell /bin/bash --system --group pajbot

#Allow pajbot account to reload nginx
echo 'pajbot ALL= NOPASSWD: /bin/systemctl reload nginx' | sudo tee -a /etc/sudoers.d/pajbot

#Create Tempdir for install files
mkdir ~/pb1tmp
PB1TMP=$HOME/pb1tmp

sudo mkdir /opt/pajbot
sudo mkdir /opt/pajbot-sock
sudo chown -R pajbot:pajbot /opt/pajbot
sudo chown -R pajbot:pajbot /opt/pajbot-sock

#Configure APT and Install Packages
if [ $ID == "ubuntu" ]; then
sudo add-apt-repository universe
fi
sudo apt update && sudo apt upgrade -y
sudo apt install mariadb-server redis-server nginx libssl-dev python3 python3-pip python3-venv python3-dev git curl build-essential -y

#Download PB1 and set it up
cat << 'EOF' > /tmp/pb1_inst.sh
cd /opt/pajbot
git clone https://github.com/pajbot/pajbot .
mkdir configs
python3 -m venv venv
source ./venv/bin/activate
python3 -m pip install wheel
python3 -m pip install -r requirements.txt
EOF
sudo chmod 777 /tmp/pb1_inst.sh
sudo su - pajbot -c "bash /tmp/pb1_inst.sh"
sudo rm /tmp/pb1_inst.sh

#Setup MySQL User
sudo mysql -e "CREATE DATABASE $PB1_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;";
sudo mysql -e "CREATE USER pajbot@localhost IDENTIFIED VIA unix_socket;"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`pb\_%\`.* to 'pajbot'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

#Setup pb1config
cat << EOF > $PB1TMP/$PB1_BRC.ini
[main]
; display name of the bot account
nickname = $PB1_NAME
; login name of the broadcaster
streamer = $PB1_BRC
; login name of the primary admin (will be granted level 2000 initially)
admin = $PB1_ADM
; an additional channel the bot will join and receive commands from.
control_hub = $PB1_HUB
; db connection, format: mysql+pymysql://username:password@host/databasename?charset=utf8mb4
db = mysql+pymysql:///$PB1_DB?unix_socket=/var/run/mysqld/mysqld.sock&charset=utf8mb4
; timezone the bot uses internally, e.g. to show the time when somebody was last seen for example
; use the names from this list https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
timezone = $PB1_TIMEZONE
; Set this to 1 (0 otherwise) to allow twitch channel moderators to create highlights
; (twitch channel moderators are completely separate from moderators on the bot, which is level 500 and above)
trusted_mods = 0
; Set this to a valid Wolfram|Alpha App ID to enable wolfram alpha query functionality
; via !add funccommand query|wolframquery query --level 250
;wolfram = ABCDEF-GHIJKLMNOP
; this location/ip is used to localize the queries to a default location.
; https://products.wolframalpha.com/api/documentation/#semantic-location
; if you specify both IP and location, the location will be ignored.
;wolfram_ip = 62.41.0.123
;wolfram_location = Amsterdam

[web]
; enabled web modules, separated by spaces. For example you could make this
; "linefarming pleblist" to enable the pleblist module additionally.
modules = linefarming playsounds
; display name of the broadcaster
streamer_name = $PB1_BRC
; domain that the website runs on
domain = $PB1_HOST
; this configures hearthstone decks functionality if you have the module enabled
deck_tab_images = 1

[streamelements]
client_id = abc
client_secret = def

[streamlabs]
client_id = abc
client_secret = def

; phrases the bot prints when it starts up and exits
[phrases]
welcome = {nickname} {version} running!
quit = {nickname} {version} shutting down...
; optional: you can make the bot print multiple messages on startup/quit,
; for example a common use for this might be to turn emote only mode on when the bot is quit
; and to turn it back off once it's back. (notice the indentation)
;welcome = {nickname} {version} running!
;    .emoteonlyoff
;quit = .emoteonly
;    {nickname} {version} shutting down...

[twitchapi]
client_id = $PB1_BOT_CLID
client_secret = $PB1_BOT_CLSEC
redirect_uri = $PB1_PROTO://$PB1_HOST/login/authorized

; you can optionally populate this with twitter access tokens
; if you want to be able to interact with twitter.
[twitter]
consumer_key = abc
consumer_secret = abc
access_token = 123-abc
access_token_secret = abc
streaming = 0

; leave these for normal bot operation
[flags]
silent = 0
; enables !eval
dev = 1

[websocket]
enabled = 1
unix_socket = /opt/pajbot-sock/$PB1_BRC-websocket.sock
host = $PB1_WS_PROTO://$PB1_HOST/clrsocket

; you can optionally populate this for pleblist
[youtube]
developer_key = abc
EOF

#Install acme.sh to manage ssl certs
if [[ $LOCAL_INSTALL = "true" ]]
then
    echo 'Local install enabled. Do not install acme.sh'
else
    if sudo test -f "/home/pajbot/.acme.sh/acme.sh"; then
        echo "acme.sh already installed. skip"
    else
        sudo su - pajbot -c 'curl https://get.acme.sh | sh'
    fi
fi

#Configure nginx
if [[ $LOCAL_INSTALL = "true" ]]
then
    echo 'Local install enabled. Do not generate DHParams'
else
    if [ -f /etc/nginx/dhparam.pem ]; then
        echo "DHParams exist. Skip generation"
    else
        sudo openssl dhparam -out /etc/nginx/dhparam.pem -dsaparam 4096
    fi
fi

if [ $OS_VER == "ubuntu1904" ]
then
cat << 'EOF' > $PB1TMP/ssl.conf
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_dhparam /etc/nginx/dhparam.pem;
ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
ssl_ecdh_curve secp384r1;
ssl_session_timeout  10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000";
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
EOF
else
cat << 'EOF' > $PB1TMP/ssl.conf
ssl_protocols TLSv1.2;
ssl_prefer_server_ciphers on;
ssl_dhparam /etc/nginx/dhparam.pem;
ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
ssl_ecdh_curve secp384r1;
ssl_session_timeout  10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000";
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
EOF
fi

if [[ $LOCAL_INSTALL = "true" ]]
then
    echo 'Local install enabled. Do not generate certificate.'
else
#Setup temporary http webroot to issue the initial certificate
cat << EOF > $PB1TMP/leissue.conf
server {
    listen 80;
    server_name $PB1_HOST;

    location /.well-known/acme-challenge/ {
        alias /var/www/le_root/.well-known/acme-challenge/;
    }
}
EOF
sudo mkdir -p /var/www/le_root/.well-known/acme-challenge
sudo chown -R pajbot:www-data /var/www/le_root
sudo rm /etc/nginx/sites-enabled/default
sudo mv $PB1TMP/leissue.conf /etc/nginx/sites-enabled/0000-issuetmp.conf
sudo systemctl restart nginx

if [[ $DEVMODE = "true" ]]
then
 sudo PB1_HOST=$PB1_HOST su pajbot -c '/home/pajbot/.acme.sh/acme.sh --force --staging --issue -d $PB1_HOST -w /var/www/le_root --reloadcmd "sudo systemctl reload nginx"'
else
 sudo PB1_HOST=$PB1_HOST su pajbot -c '/home/pajbot/.acme.sh/acme.sh --force --issue -d $PB1_HOST -w /var/www/le_root --reloadcmd "sudo systemctl reload nginx"'
fi

sudo rm /etc/nginx/sites-enabled/0000-issuetmp.conf
fi

if [[ $LOCAL_INSTALL = "true" ]]
then
    echo 'Local install enabled. Copy vhost config without ssl settings.'
#pb1 vhost no ssl
cat << EOF > $PB1TMP/pajbot1-$PB1_BRC.conf
upstream $PB1_BRC-botsite {
    server unix:///opt/pajbot-sock/$PB1_BRC-web.sock;
}
upstream $PB1_BRC-websocket {
    server unix:///opt/pajbot-sock/$PB1_BRC-websocket.sock;
}

server {
    listen 80;
    listen [::]:80;
    server_name $PB1_HOST;

    charset utf-8;

    location /api/ {
        uwsgi_pass $PB1_BRC-botsite;
        include uwsgi_params;
        expires epoch;
    }

    location / {
        uwsgi_pass $PB1_BRC-botsite;
        include uwsgi_params;
        expires epoch;
        add_header Cache-Control "public";
    }

    location /clrsocket {
        proxy_pass http://$PB1_BRC-websocket/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
}
EOF
else
#pb1 vhost ssl
cat << EOF > $PB1TMP/pajbot1-$PB1_BRC.conf
upstream $PB1_BRC-botsite {
    server unix:///opt/pajbot-sock/$PB1_BRC-web.sock;
}
upstream $PB1_BRC-websocket {
    server unix:///opt/pajbot-sock/$PB1_BRC-websocket.sock;
}

server {
    listen 80;
    listen [::]:80;
    server_name $PB1_HOST;

    location /.well-known/acme-challenge/ {
        alias /var/www/le_root/.well-known/acme-challenge/;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }

}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $PB1_HOST;
    ssl_certificate /home/pajbot/.acme.sh/$PB1_HOST/fullchain.cer;
    ssl_certificate_key /home/pajbot/.acme.sh/$PB1_HOST/$PB1_HOST.key;

    charset utf-8;

    location /api/ {
        uwsgi_pass $PB1_BRC-botsite;
        include uwsgi_params;
        expires epoch;
    }

    location / {
        uwsgi_pass $PB1_BRC-botsite;
        include uwsgi_params;
        expires epoch;
        add_header Cache-Control "public";
    }

    location /clrsocket {
        proxy_pass http://$PB1_BRC-websocket/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
    }
}
EOF
fi

#nginx main config
cat << 'EOF' > $PB1TMP/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
        worker_connections 768;
}

http {
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout 65;
        types_hash_max_size 2048;
        server_tokens off;
        server_names_hash_bucket_size 64;

        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        log_format customformat '[$time_local] $remote_addr '
                '$host "$request" $status '
                '"$http_referer" "$http_user_agent"';

        access_log /var/log/nginx/access.log customformat;
        error_log /var/log/nginx/error.log;

        gzip on;

        include /etc/nginx/conf.d/*.conf;
        include /etc/nginx/sites-enabled/*;
}

EOF

if [[ $LOCAL_INSTALL = "true" ]]
then
    echo 'Local install enabled. Do not copy ssl config.'
else
    if [ -f /etc/nginx/conf.d/ssl.conf ]; then
        echo "SSL config exists. skip copy"
    else
        sudo mv $PB1TMP/ssl.conf /etc/nginx/conf.d/ssl.conf
    fi
fi

#Setup catchall vhost
if [[ $LOCAL_INSTALL = "true" ]]
then
echo 'Local install enabled. Create catchall config without https'
cat << EOF > $PB1TMP/catchall.conf
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    access_log off;

    location / {
        return 404;
    }
}
EOF
else
cat << EOF > $PB1TMP/catchall.conf
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    access_log off;
    ssl_certificate /home/pajbot/.acme.sh/$PB1_HOST/fullchain.cer;
    ssl_certificate_key /home/pajbot/.acme.sh/$PB1_HOST/$PB1_HOST.key;

    location / {
        return 404;
    }
}
EOF
fi

if [ -f /etc/nginx/sites-enabled/catchall.conf ]; then
    echo "Catchall config exists. skip copy"
else
    sudo mv $PB1TMP/catchall.conf /etc/nginx/sites-available/catchall.conf
    sudo ln -s /etc/nginx/sites-available/catchall.conf /etc/nginx/sites-enabled/
fi

sudo mv $PB1TMP/nginx.conf /etc/nginx/nginx.conf
sudo mv $PB1TMP/pajbot1-$PB1_BRC.conf /etc/nginx/sites-available/pajbot1-$PB1_BRC.conf
sudo ln -s /etc/nginx/sites-available/pajbot1-$PB1_BRC.conf /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo systemctl restart nginx

#Configure pajbot Systemd Units
cat << 'EOF' > $PB1TMP/pajbot-web@.service
[Unit]
Description=pajbot-web for %i
After=network.target

[Service]
Type=simple
User=pajbot
Group=pajbot
WorkingDirectory=/opt/pajbot
ExecStart=/opt/pajbot/venv/bin/uwsgi --ini uwsgi_shared.ini --socket /opt/pajbot-sock/%i-web.sock --pyargv "--config configs/%i.ini" --virtualenv venv
RestartSec=2
Restart=always

[Install]
WantedBy=multi-user.target
EOF
cat << 'EOF' > $PB1TMP/pajbot@.service
[Unit]
Description=pajbot for %i
After=network.target

[Service]
Type=simple
User=pajbot
Group=pajbot
WorkingDirectory=/opt/pajbot
Environment=VIRTUAL_ENV=/opt/pajbot/venv
ExecStart=/bin/bash -c "PATH=$VIRTUAL_ENV/bin:$PATH /opt/pajbot/venv/bin/python3 main.py --config configs/%i.ini"
RestartSec=2
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo mv $PB1TMP/$PB1_BRC.ini /opt/pajbot/configs/$PB1_BRC.ini
sudo chown pajbot:pajbot /opt/pajbot-sock
sudo chown -R pajbot:pajbot /opt/pajbot

#Enable systemd services for the bot and start it up.
sudo mv $PB1TMP/pajbot@.service /etc/systemd/system/
sudo mv $PB1TMP/pajbot-web@.service /etc/systemd/system/
sudo systemctl daemon-reload
sleep 2
sudo systemctl enable pajbot@$PB1_BRC
sudo systemctl enable pajbot-web@$PB1_BRC
sudo systemctl start pajbot@$PB1_BRC
echo 'Waiting 20 seconds for bot to initialize and starting the webui after that.'
sleep 20
sudo systemctl start pajbot-web@$PB1_BRC

#Done
echo "pajbot1 Installed. Access the web interface in $PB1_PROTO://$PB1_HOST"
echo "Access $PB1_PROTO://$PB1_HOST/bot_login and login with your bot account."

sudo rm -rf /tmp/sudotag
sudo rm -rf $PB1TMP

exit 0