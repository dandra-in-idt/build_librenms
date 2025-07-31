#!/bin/bash

#Installer les dÃ©pendances de LibreNMS :
sudo apt install lsb-release ca-certificates wget acl curl fping git graphviz imagemagick mariadb-client mariadb-server mtr-tiny nginx-full nmap php-cli php-curl php-fpm php-gd php-gmp php-mbstring php-mysql php-snmp php-xml php-zip python3-dotenv python3-pymysql python3-redis python3-setuptools python3-systemd python3-pip rrdtool snmp snmpd unzip whois python3.11-venv -y
#CrÃ©er l'utilisateur LibreNMS :

sudo useradd librenms -d /opt/librenms -M -r -s "$(which bash)"
sudo passwd librenms
read -p "Meme password pour la bdd : " PASSWORD_BDD
#Installer les fichiers LibreNMS depuis GitHub :

cd /opt
sudo git clone https://github.com/librenms/librenms.git
sudo chown -R librenms:librenms /opt/librenms
sudo chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

wget https://getcomposer.org/composer-stable.phar
mv composer-stable.phar /usr/bin/composer
chmod +x /usr/bin/composer
chown librenms:root /usr/bin/composer
su - librenms -c "/opt/librenms/scripts/composer_wrapper.php install --no-dev"
su - librenms -c "pip install -r requirements.txt --break-system-packages"

read -p "Time format Continent/Capitale : " time
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
sudo rm -rf /etc/php/$PHP_VERSION/fpm/php.ini /etc/php/$PHP_VERSION/cli/php.ini
sudo echo "
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
upload_max_filesize = 16M
post_max_size = 16M

extension=curl
extension=gd
extension=mbstring
extension=mysqlnd
extension=openssl
extension=snmp
extension=xml
extension=zip

date.timezone = "\"$time\""

error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /var/log/php_errors.log
" > /etc/php/$PHP_VERSION/fpm/php.ini
sudo cp  /etc/php/$PHP_VERSION/fpm/php.ini /etc/php/$PHP_VERSION/cli/php.ini

sudo rm -rf /etc/mysql/mariadb.conf.d/50-server.cnf
echo "
[server]

[mysqld]

pid-file                = /run/mysqld/mysqld.pid
basedir                 = /usr
innodb_file_per_table   = 1
lower_case_table_names  = 0
bind-address            = 127.0.0.1
expire_logs_days        = 10
character-set-server  = utf8mb4
collation-server      = utf8mb4_general_ci

[embedded]

[mariadb]

[mariadb-10.11]
" > /etc/mysql/mariadb.conf.d/50-server.cnf

mysql -u root -p -e "
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '$PASSWORD_BDD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
"
rm /etc/php/8.2/fpm/pool.d/www.conf 
echo "
[librenms]
user = librenms
group = librenms
listen = /var/php-fmp-librenms.sock
listen.owner = librenms
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 10
" > /etc/php/8.2/fpm/pool.d/librenms.conf
echo "
server {
 listen      80;
 server_name librenms.example.com;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;
 location / {
  try_files $uri $uri/ /index.php?$query_string;
 }
 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
" > /etc/nginx/sites-enabled/librenms.vhost

rm /etc/nginx/sites-enabled/default
systemctl reload nginx
systemctl restart php8.2-fpm

ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

rm /etc/snmp/snmpd.conf

echo "
               #ip_server_librenms  #community (password)
com2sec readonly  10.12.0.5         admin_ivv_librenms

group MyROGroup v2c        readonly
view all    included  .1                               80
access MyROGroup ""      any       noauth    exact  all    none   none

syslocation Rack, Room, Building, City, Country [Lat, Lon]
syscontact Your Name <your@email.address>

            #community
rocommunity admin_ivv_librenms
extend distro /usr/bin/distro
" > /etc/snmp/snmpd.conf

curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd

cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms
sudo cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
sudo systemctl enable librenms-scheduler.timer
sudo systemctl start librenms-scheduler.timer
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
systemctl enable php$PHP_VERSION-fpm --now
systemctl enable nginx --now

curl http://127.0.0.1:80/install
