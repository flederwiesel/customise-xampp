#!/bin/bash

readonly SCRIPTDIR=$(realpath $(dirname "${BASH_SOURCE[0]}"))

for arg
do
	case "$arg" in
	-h|--help)
		cat <<"EOF"
Usage:

In an elevated shell run:

  USERPROFILE=/home/$SUDO_USER /path/to/customise.sh

EOF
		exit
		;;
	esac
done

# Is user admin?
id -G | grep -q '\<544\>' ||
{
	echo "This script must be run as admin." >&2
	exit 1
}

###### config files matching XAMPP Version 8.0.13 ######

# Apache 2.4.56
# MariaDB 10.4.28
# PHP 8.2.4
# phpMyAdmin 5.2.1
# OpenSSL 1.1.1t
# XAMPP Control Panel 3.3.0

set -e

shopt -s expand_aliases

alias mysql='mysql --protocol=TCP --skip-column-names'

[ -f "$USERPROFILE/xampp.conf" ] &&
source "$USERPROFILE/xampp.conf" && echo sourced "$USERPROFILE/xampp.conf"

[ -f "$HOME/xampp.conf" ] && [ "$USERPROFILE" != "$HOME" ] &&
source "$HOME/xampp.conf" && echo sourced "$HOME/xampp.conf"

cd "$xampp"

# Create base dirs

for v in \
 xampp \
 tmp \
 var \
 run \
 log \

do
	[[ "${!v}" ]] ||
	{
		echo "${v} must be set." >&2
		exit 1
	}

	mkdir -p "${!v}"
done

# Stop services if running

echo -e "\033[36mStopping services ...\033[m"

for s in Apache2.4 mysql
do
	sc query "$s" | grep -q 'STATE *: 4  RUNNING' &&
	{
		sc stop "$s" &>/dev/null &&
		while ! sc query "$s" | grep -q 'STATE *: 1  STOPPED'
		do
			echo -n .
		done

		echo
	}
done

################################################################################

replace="s|%{xampp}|${xampp}|g
s|%{tmp}|${tmp}|g
s|%{var}|${var}|g
s|%{run}|${run}|g
s|%{log}|${log}|g
s|%{mysql_data}|${mysql_data}|g
"

### apache #####################################################################

[[ $vhosts ]] ||
{
	echo "${v} must be set." >&2
	exit 1
}

for vhost in ${vhosts[@]}
do
	mkdir -p "$xampp/apache/conf/extra/vhosts/ssl" "${log}/apache2/${vhost}"

	for v in \
	 .key \
	 .crt \
	 -chain.crt \

	do
		ext=${v//./_}
		ext=${ext//-/_}
		f="${vhost}_ssl${ext}"

		[[ "${!f}" ]] ||
		{
			echo "$f must be set." >&2
			exit 1
		}

		if [[ ${!f:0:10} = "-----BEGIN" ]]; then
			echo "${!f}" > "$xampp/apache/conf/extra/vhosts/ssl/${vhost}${v}"
		else
			cp "${!f}" "$xampp/apache/conf/extra/vhosts/ssl/${vhost}${v}"
		fi
	done

	DocumentRoot="${vhost}_DocumentRoot"
	curlrc="${vhost}_curlrc"

	sed "$replace
		s|%{vhost}|${vhost}|g
		s|%{DocumentRoot}|${!DocumentRoot}|g
		s|%{curlrc}|${!curlrc:+\n\tSetEnv curlrc \"${!curlrc}\"\n}|g
	" "$SCRIPTDIR/xampp/apache/conf/extra/vhosts/vhost.conf" > \
	 "$xampp/apache/conf/extra/vhosts/${vhost}.conf"
done

for f in \
	"extra/httpd-dav.conf" \
	"extra/httpd-mpm.conf" \
	"extra/httpd-ssl.conf" \
	"extra/httpd-xampp.conf" \
	"httpd.conf" \

do
	sed "$replace; s|%{vhost}|${vhost}|g" \
		"$SCRIPTDIR/xampp/apache/conf/${f}" > \
		"$xampp/apache/conf/${f}"
done

for f in \
	"extra/httpd-vhosts.conf" \

do
	cp "$SCRIPTDIR/xampp/apache/conf/${f}" \
	  "$xampp/apache/conf/${f}"
done

rm -f "$xampp/apache/conf/extra/httpd-userdir.conf"

### php ########################################################################

cp "$SCRIPTDIR/xampp/php/mailtodisk" "$xampp/php/"

"$xampp/php/mailtodisk" --install

sed "$replace" "$SCRIPTDIR/xampp/php/php.ini" > "$xampp/php/php.ini"

[[ ${php_debugger[@]} ]] && cp "${php_debugger[@]}" "$xampp/php/ext"

if [[ "$php_debugger" ]]; then
	cat <<-EOF >> "$xampp/php/php.ini"
		zend_extension = "$php_debugger"

		[debugger]
		debugger.JIT_enabled = Off
		debugger.JIT_level = 3
		debugger.hosts_deny = ALL
		debugger.hosts_allow = localhost, ::1, 127.0.0.1
		debugger.ports = 7869
		debugger.enabled = on
EOF
fi

### phpMyAdmin #################################################################

cp -r "$SCRIPTDIR/xampp/phpMyAdmin/themes" "$SCRIPTDIR/xampp/phpMyAdmin/favicon.ico" "$xampp/phpMyAdmin/"

password="mysql_password_${mysql_rename_root:-root}"
password="${!password}"

sed "
	s|%{phpMyAdmin_secret}|$(head -c 16 /dev/urandom | base64)|g
	s/%{root}/${mysql_rename_root:-root}/g
	s/%{password}/$password/g
" "$SCRIPTDIR/xampp/phpMyAdmin/config.inc.php" > \
 "$xampp/phpMyAdmin/config.inc.php"

### mysql ######################################################################

for f in \
	bin/my.ini \
	data/my.ini \

do
	[[ -d "$xampp/mysql/${f%/*}" ]] &&
	sed "$replace
		${mysql_data:+s|%{mysql_data}|$mysql_data}|g
	" "$SCRIPTDIR/xampp/mysql/$f" > "$xampp/mysql/$f"
done

rm -f "$xampp/mysql/data/"*.{err,pid,log}

if [[ "$mysql_data" ]]; then
	if [ -d "$xampp/mysql/data" ]; then
		if [ ! -d "$mysql_data" ]; then
			dest=$(cygpath "$mysql_data")
			dest=$(dirname "$dest")

			mkdir -p "$dest"
			cp -R "$xampp/mysql/data" "$dest"
			chown -R "SYSTEM:SYSTEM" "$dest"
		fi
	fi
fi

### Add firewall rules #########################################################

echo -e "\033[36mAdding firewall rules ...\033[m"

# No mixed paths allowed here...

httpd=$( cygpath --windows "$xampp/apache/bin/httpd.exe")
mysqld=$(cygpath --windows "$xampp/mysql/bin/mysqld.exe")

{
modify=
netsh advfirewall firewall show rule name="Apache HTTP Server" && modify=set
netsh advfirewall firewall ${modify:-add} rule name="Apache HTTP Server" ${modify:+new} \
	program="$httpd" dir=in action=allow edge=no \
	protocol=tcp localport=80,443,8080,8088,8443,8888 remoteip=127.0.0.1

modify=
netsh advfirewall firewall show rule name="mysqld" && modify=set
netsh advfirewall firewall ${modify:-add} rule name="mysqld" ${modify:+new} \
	program="$mysqld" dir=in action=allow edge=no protocol=tcp localport=3306 remoteip=127.0.0.1
} > /dev/null

# (Re-)create services

echo -e "\033[36m(Re-)creating services ...\033[m"

# Add user (is not exists) www in group www-data, remove www from Users group

net localgroup "www-data" &>/dev/null || net localgroup /add "www-data" > /dev/null
# Expand escape sequences
password_www=$(echo -en "$password_www")
# Use "/y" option to allow password longer than 14 characters:
# https://serverfault.com/questions/452894/force-net-user-command-to-set-password-longer-than-14-characters
net user "www" &>/dev/null || net user "www" "$password_www" /add /y /active:yes /passwordreq:yes /passwordchg:no > /dev/null
wmic useraccount WHERE "Name='www'" set PasswordExpires=false > /dev/null
net localgroup "www-data" | grep -q $'^www\r''$' || net localgroup "www-data" /add "www" > /dev/null
net localgroup "Users"    | grep -q $'^www\r''$' && net localgroup "Users" /delete "www" > /dev/null

{
sc query Apache2.4 &>/dev/null && sc delete Apache2.4
sc query mysql     &>/dev/null && sc delete mysql

sc create Apache2.4 binPath= "$httpd -k runservice" obj= '.\www' password= "$password_www" start= auto
sc create mysql     binPath= "$mysqld --defaults-file=\"$xampp/mysql/bin/my.ini\" mysql" start= auto

sc description Apache2.4 "XAMPP Apache 2.4.56 / OpenSSL 1.1.1t / PHP 8.2.4"
sc description mysql     "XAMPP MariaDB 10.4.28"
} > /dev/null

# Start services

echo -e "\033[36mStarting services ...\033[m"

for s in Apache2.4 mysql
do
	start=$(date +%s)

	sc query "$s" | grep -q 'STATE *: 4  RUNNING' ||
	{
		sc start "$s" &>/dev/null &&
		while ! sc query "$s" | grep -q 'STATE *: 4  RUNNING'
		do
			[ $(($(date +%s) - $start)) -gt 10 ] && exit 2
			echo -n .
		done

		echo
	}
done

### post-install ###############################################################

# Initial credentials are "root" user and empty password

if mysql --user=root <<< '' &>/dev/null; then
	root=root
	password=
else
	if [[ "$mysql_rename_root" ]]; then
		user="$mysql_rename_root"
		pass="mysql_password_$mysql_rename_root"
		pass="${!pass}"
	else
		user=root
		pass="$mysql_password_root"
	fi

	if [[ "$pass" ]]; then
		# Try changed user name and password
		if mysql --user="$user" --password="$pass" <<< '' &>/dev/null; then
			root="$user"
			password="$pass"
		else
			exit $LINENO
		fi
	else
		# Try changed user name and empty password
		if mysql --user="$user" <<< '' &>/dev/null; then
			root="$user"
			password=
		else
			exit $LINENO
		fi
	fi
fi

mysql --user="$root" ${password:+--password="$password"} < <(

	IFS=$'\n'

	if [[ "${mysql_rename_root}" ]]; then
		hosts=($(
			mysql --user="$root" ${password:+--password="$password"} --batch <<-EOF
				SELECT \`Host\`
				FROM \`mysql\`.\`user\`
				WHERE \`User\` = 'root';
EOF
		))

		for host in "${hosts[@]}"
		do
			# Update DEFINER of views
			views=($(
				mysql --user="$root" ${password:+--password="$password"} --batch <<-EOF
					SELECT \`TABLE_SCHEMA\`, \`TABLE_NAME\`, \`VIEW_DEFINITION\`
					FROM \`information_schema\`.\`views\`
					WHERE \`DEFINER\` = 'root@$host';
EOF
			))

			echo "RENAME USER 'root'@'$host' TO '$mysql_rename_root'@'$host';"

			for view in "${views[@]}"
			do
				IFS=$'\t' read schema name definition <<< "$view"
				echo "ALTER DEFINER = '$mysql_rename_root'@'localhost' VIEW \`$schema\`.\`$name\` AS $definition;"
			done
		done
	fi

	for user in "${mysql_users[@]}" "${mysql_rename_root:-root}"
	do
		pass="mysql_password_$user"
		pass="${!pass}"
		pass="${pass//\'/\\\'}"

		if [ "${mysql_rename_root:-root}" = "$user" ]; then
			if [[ "$pass" ]]; then
				# In a default installation, root is present on multiple hosts:
				# localhost, 127.0.0.1, ::1,
				hosts=($(
					mysql --user="$root" ${password:+--password="$password"} --batch <<-EOF
						SELECT \`Host\`
						FROM \`mysql\`.\`user\`
						WHERE \`User\` = 'root';
EOF
				))

				for host in "${hosts[@]}"
				do
					echo "ALTER USER '${mysql_rename_root:-root}'@'$host' IDENTIFIED BY '$pass' PASSWORD EXPIRE NEVER;"
				done
			fi
		else
			echo "CREATE USER IF NOT EXISTS '$user'@'localhost';"
			echo "ALTER USER '$user'@'localhost' IDENTIFIED BY '$pass' PASSWORD EXPIRE NEVER;"

			if [ "$user" != "${mysql_rename_root:-root}" ]; then
				grant="mysql_grant_$user"
				grant="${!grant}"
				echo "GRANT ${grant:-$mysql_grant__default} ON *.* TO '$user'@'localhost';"
			fi

			db="mysql_database_$user"
			db="${!db}"

			if [[ "$db" ]]; then
				echo "CREATE DATABASE IF NOT EXISTS \`$db\`;"
				echo "GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'localhost';"
			fi
		fi
	done

	echo "FLUSH PRIVILEGES;"
	echo "DROP DATABASE IF EXISTS \`test\`;"
)

# Use `mysql_tzinfo_to_sql /usr/share/zoneinfo > zoneinfo.sql` on a Linux host to create tz script
cp "$SCRIPTDIR/xampp/mysql/share/zoneinfo.sql" "$xampp/mysql/share/"
mysql --user="$root" ${password:+--password="$password"} --database=mysql < "$xampp/mysql/share/zoneinfo.sql"

### webalizer ##################################################################

echo "Sorry, no stats available (yet)." > "$xampp/htdocs/webalizer/index.htm"

### xampp-control.exe ##########################################################

sed "s/%{editor}/${editor:-notepad.exe}/g" \
	"$SCRIPTDIR/xampp/xampp-control.ini" > "$xampp/xampp-control.ini"

chmod 666 "$xampp/xampp-control.ini"

echo -e "\033[32m=== SUCCESS. ===\033[m"
