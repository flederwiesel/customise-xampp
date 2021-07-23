#!/bin/bash

###### config files matching XAMPP Version 8.0.2 ######

set -e

shopt -s expand_aliases

alias mysql='mysql --protocol=TCP --skip-column-names'

[ -f "$USERPROFILE/xampp.conf" ] &&
source "$USERPROFILE/xampp.conf" && echo sourced "$USERPROFILE/xampp.conf"

[ -f "$HOME/xampp.conf" ] && [ "$USERPROFILE" != "$HOME" ] &&
source "$HOME/xampp.conf" && echo sourced "$HOME/xampp.conf"

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

cd $(dirname "$0")

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
	" "xampp/apache/conf/extra/vhosts/vhost.conf" > \
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
		"xampp/apache/conf/${f}" > \
		"$xampp/apache/conf/${f}"
done

for f in \
	"extra/httpd-vhosts.conf" \

do
	cp "xampp/apache/conf/${f}" \
	  "$xampp/apache/conf/${f}"
done

rm -f "$xampp/apache/conf/extra/httpd-userdir.conf"

### php ########################################################################

cp "xampp/php/mailtodisk" "$xampp/php/"

sed "$replace" "xampp/php/php.ini" > "$xampp/php/php.ini"

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

cp -r "xampp/phpMyAdmin/themes" "xampp/phpMyAdmin/favicon.ico" "$xampp/phpMyAdmin/"

password="mysql_password_$mysql_rename_root"
password="${!password}"

sed "
	s|%{phpMyAdmin_secret}|$(head -c 16 /dev/urandom | base64)|g
	s/%{root}/${mysql_rename_root:-root}/g
	s/%{password}/$password/g
" "xampp/phpMyAdmin/config.inc.php" > \
 "$xampp/phpMyAdmin/config.inc.php"

### mysql ######################################################################

for f in \
	bin/my.ini \
	data/my.ini \

do
	sed "$replace
		${mysql_data:+s|%{mysql_data}|$mysql_data}|g
	" "xampp/mysql/$f" > "$xampp/mysql/$f"
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

(
# Error: Current working directory has restricted permissions which render it
# inaccessible as Win32 working directory.
# Can't start native Windows application from here.

cd /tmp

modify=
netsh advfirewall firewall show rule name="Apache HTTP Server" && modify=set
netsh advfirewall firewall ${modify:-add} rule name="Apache HTTP Server" ${modify:+new} \
	program="$httpd" dir=in action=allow \
	protocol=tcp localport=80,443,8080,8088,8443,8888

modify=
netsh advfirewall firewall show rule name="mysqld" && modify=set
netsh advfirewall firewall ${modify:-add} rule name="mysqld" ${modify:+new} \
	program="$mysqld" dir=in action=allow protocol=tcp localport=3306
) > /dev/null

# Create services if not exist

echo -e "\033[36mCreating services if not exist ...\033[m"

(
# Error: Current working directory has restricted permissions which render it
# inaccessible as Win32 working directory.
# Can't start native Windows application from here.

cd /tmp

sc query Apache2.4 &>/dev/null || sc create Apache2.4 binPath= "$httpd -k runservice" start= auto
sc query mysql     &>/dev/null || sc create mysql     binPath= "$mysqld --defaults-file=\"$xampp/mysql/bin/my.ini\" mysql" start= auto
)

# Start services

echo -e "\033[36mStarting services ...\033[m"

(
# Error: Current working directory has restricted permissions which render it
# inaccessible as Win32 working directory.
# Can't start native Windows application from here.

cd /tmp

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
)

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
	if [[ "${mysql_rename_root}" ]]; then
		if [ "root" = "$root" ]; then
			mysql --user="$root" ${password:+--password="$password"} <<-EOF
				SELECT CONCAT("RENAME USER 'root'@'", \`Host\`, "' TO '$mysql_rename_root'@'", \`Host\`, "';")
				FROM \`mysql\`.\`user\`
				WHERE \`User\` = 'root';

				# Update DEFINER of views
				SELECT CONCAT("ALTER DEFINER = '$mysql_rename_root'@'localhost' VIEW \`", \`TABLE_SCHEMA\`, "\`.\`", \`TABLE_NAME\`, "\` AS ", \`VIEW_DEFINITION\`, ";")
				FROM \`information_schema\`.\`views\`
				WHERE \`DEFINER\` = 'root@localhost';
EOF
			# Update DEFINER of stored procedures
			echo "UPDATE \`mysql\`.\`proc\` p SET \`DEFINER\` = '$mysql_rename_root@%' WHERE \`DEFINER\` = 'root@%';"
		fi
	fi

	if [[ "${mysql_users[@]}" ]]; then
		for user in "${mysql_rename_root:-root}" "${mysql_users[@]}" pma
		do
			pass="mysql_password_$user"
			pass="${!pass}"
			pass="${pass//\'/\\\'}"

			if [ "${mysql_rename_root:-root}" = "$user" ]; then
				if [[ "$pass" ]]; then
					mysql --user="$root" ${password:+--password="$password"} <<-EOF
						SELECT CONCAT("ALTER USER '${mysql_rename_root:-root}'@'", \`Host\`, "' IDENTIFIED BY '$pass' PASSWORD EXPIRE NEVER;")
						FROM \`mysql\`.\`user\`
						WHERE \`User\` = '${mysql_rename_root:-root}'
EOF
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
	fi

	echo "FLUSH PRIVILEGES;"

	echo "DROP DATABASE IF EXISTS \`test\`;"
)

### webalizer ##################################################################

echo "Sorry, no stats available (yet)." > "$xampp/htdocs/webalizer/index.htm"

### xampp-control.exe ##########################################################

sed "s/%{editor}/${editor:-notepad.exe}/g" \
	"xampp/xampp-control.ini" > "$xampp/xampp-control.ini"

chmod 666 "$xampp/xampp-control.ini"
