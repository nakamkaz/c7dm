echo " *** Firewall, DNS, Proxy "
#######################################
# Loading utility function
if [ ! -e c7dm.util ]; then
echo c7dm.util is required. Bye!
exit 
fi
. ./c7dm.util
if [ ! -e c7dm.conf ]; then
echo c7dm.conf is required! Bye!
exit
fi 
. ./c7dm.conf

echo "---- change firewall zone and routing "
loudrun firewall-cmd --zone=${target_zone} --add-interface=${eth_dev} 
loudrun firewall-cmd --permanent --zone=${target_zone} --add-interface=${eth_dev}
nmcli conn mod ${nw_conn} connection.zone ${target_zone}

echo "---- configure ProxyServer "
loudrun yum -y install squid
loudrun systemctl stop squid
loudrun firewall-cmd --permanent --add-port=3128/tcp --zone=${target_zone}

if [ ! -e squid.conf_*.bak ]; then
echo "---- change /etc/squid/squid.conf "
loudrun backupconf /etc/squid/squid.conf
echo cache_dir null /dev/null >> /etc/squid/squid.conf
echo cache_mem 128 MB >> /etc/squid/squid.conf
fi

loudrun systemctl restart squid
loudrun systemctl enable squid
loudrun systemctl status squid

echo "---- proxy setup finished."

echo "---- begin to install bind bind-chroot bind-utils"
loudrun yum -y install bind bind-chroot bind-utils bind-utils

ip0_noprefix=$(gawk -v x=${myip} 'BEGIN{split(x,ar,"/");print ar[1]}')
forwarddns=$(gawk -v x=${dnss} 'BEGIN{split(x,ar,",");print ar[1]}')

#if [ -z ${forwarddns} ]; then
#forwarddns=8.8.8.8
#fi

loudrun firewall-cmd --add-service=dns --zone=${target_zone}
loudrun firewall-cmd --add-service=dns --zone=${target_zone} --permanent

loudrun systemctl stop named.service
loudrun systemctl disable named.service
loudrun systemctl stop named-chroot.service

echo ---- create zonefile and add the zonefile to /var/named/.

loudrun backupconf /var/named/${masterdomain}.zone

cat << __MYZONEFILE__ > /var/named/${masterdomain}.zone
\$TTL 86400
@ IN SOA localhost. root.${masterdomain}. (
					$(date +%Y%m%d%H); Serial
					28800 ; Refresh
					14400 ; Retry
					3600000 ; Expire
					86400 ) ; Minimum
${masterdomain}.	IN NS	${nhost}.${masterdomain}.
${masterdomain}.	IN MX	10	${nhost}.${masterdomain}.
${nhost}		IN	A	${ip0_noprefix}
__MYZONEFILE__

echo change owner /var/named/${masterdomain}.zone
loudrun chown root:named /var/named/${masterdomain}.zone

echo change /etc/named.conf
loudrun backupconf /etc/named.conf

cat << __MYNAMEDCONF__ > /etc/named.conf
//
// named.conf
//
// Provided by Red Hat bind package to configure the ISC BIND named(8) DNS
// server as a caching only nameserver (as a localhost DNS resolver only).
//
// See /usr/share/doc/bind*/sample/ for example named configuration files.
//
options {
listen-on port 53 { any; };
#listen-on-v6 port 53 { ::1; };
directory "/var/named";
dump-file "/var/named/data/cache_dump.db";
statistics-file "/var/named/data/named_stats.txt";
memstatistics-file "/var/named/data/named_mem_stats.txt";
allow-query { any; };

/*
- If you are building an AUTHORITATIVE DNS server, do NOT enable recursion.
- If you are building a RECURSIVE (caching) DNS server, you need to enable
recursion.
- If your recursive DNS server has a public IP address, you MUST enable access
control to limit queries to your legitimate users. Failing to do so will
cause your server to become part of large scale DNS amplification
attacks. Implementing BCP38 within your network would greatly
reduce such attack surface
*/
recursion yes;
dnssec-enable yes;
dnssec-validation yes;
dnssec-lookaside auto;
/* Path to ISC DLV key */
bindkeys-file "/etc/named.iscdlv.key";
managed-keys-directory "/var/named/dynamic";
pid-file "/run/named/named.pid";
session-keyfile "/run/named/session.key";
forwarders{ ${forwarddns}; };
};
logging {
channel default_debug {
file "data/named.run";
severity dynamic;
};
};
zone "." IN {
type hint;
file "named.ca";
};

zone "${masterdomain}" IN { 
type master; 
file "${masterdomain}.zone";
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";

__MYNAMEDCONF__

echo "change owner /etc/named.conf"
loudrun chown root:named /etc/named.conf
loudrun systemctl start named-chroot.service
loudrun systemctl enable named-chroot.service

echo "---- Setup ISC BIND DONE.

echo ---- change DNS1,2 to 127.0.0.1 and ${forwarddns}.
loudrun nmcli con mod ${nw_conn} ipv4.dns "127.0.0.1,${forwarddns}"

echo "----Setup Postfix Dovecot SASL"
echo "---- Modify firewall for mail
loudrun firewall-cmd --permanent --add-service=smtp --zone=${target_zone}
loudrun firewall-cmd --permanent --add-service=pop3s --zone=${target_zone}
loudrun firewall-cmd --permanent --add-service=imaps --zone=${target_zone}
loudrun firewall-cmd --permanent --add-port=110/tcp --zone=${target_zone}
loudrun firewall-cmd --permanent --add-port=143/tcp --zone=${target_zone}

echo ---- TODO: Install or Update Dovecot cyrus-sasl
loudrun yum -y install dovecot cyrus-sasl cyrus-sasl-plain
loudrun systemctl stop postfix
loudrun systemctl enable postfix
loudrun systemctl stop dovecot
loudrun systemctl enable dovecot
loudrun systemctl stop saslauthd
loudrun systemctl enable saslauthd

loudrun backupconf /etc/postfix/main.cf
loudrun backupconf /etc/dovecot/dovecot.conf

#  my local network
myip1=$(ip -4 -f inet  -o addr | grep ${eth_dev} | awk '{print $4}')
myip1net=$(ipcalc --network ${myip1} | sed s/NETWORK=//)
myip1pre=$(ipcalc --prefix ${myip1} | sed s/PREFIX=//)

echo "run Post Conf"
loudrun postconf broken_sasl_auth_clients=yes
loudrun postconf home_mailbox=Maildir/
loudrun postconf inet_interfaces=all
loudrun postconf inet_protocols=ipv4
loudrun postconf mydestination='$myhostname,localhost.$mydomain,localhost,$mydomain'
loudrun postconf mydomain=${masterdomain}
loudrun postconf myhostname=${nhost}.${masterdomain}
loudrun postconf mynetworks=${myip1net}/${myip1pre},127.0.0.0/8
loudrun postconf myorigin=\$mydomain
#loudrun postconf relay_recipient_maps=hash:/etc/postfix/relay_recipients
loudrun postconf smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd
loudrun postconf smtpd_recipient_restrictions='permit_mynetworks,permit_sasl_authenticated'
loudrun postconf smtpd_sasl_auth_enable=yes
loudrun postconf -n

echo "create Maildir in skel"
loudrun mkdir -p /etc/skel/Maildir/{new,cur,tmp}
loudrun chmod -R 700 /etc/skel/Maildir/

loudrun systemctl restart postfix
loudrun systemctl restart dovecot
loudrun systemctl restart saslauthd

