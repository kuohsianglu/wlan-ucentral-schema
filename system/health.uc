#!/usr/bin/ucode
push(REQUIRE_SEARCH_PATH, '/usr/share/ucentral/*.uc');
let fs = require("fs");
let uci = require("uci");
let ubus = require("ubus");

if (length(fs.stat('/tmp/ucentral.health')))
	sleep(75000);

fs.unlink('/tmp/ucentral.health');

state = {
	unit: {},
	interfaces: {}
};

let ctx = ubus.connect();
let interfaces = ctx.call("network.interface", "dump").interface;
let cursor = uci.cursor();
cursor.load("dhcp");
cursor.load("network");
cursor.load("wireless");
let dhcp = cursor.get_all("dhcp");
let wifi_config = cursor.get_all("wireless");
let wifi_state = require('wifi.iface');
let count = 0;

function find_ssid(ssid) {
	for (let name, iface in wifi_state)
		if (ssid == iface.ssid)
			return 0;
	return 1;
}

function radius_probe(server, port, secret)
{
	let f = fs.open("/tmp/radius.conf", "w");
	if (f) {
		f.write(sprintf("authserver %s:%d\n", server, port));
		f.write("servers /tmp/radius.servers\n");
		f.write("dictionary /etc/radcli/dictionary\n");
		f.write("radius_timeout 3\n");
		f.write("radius_retries 1\n");
		f.write("bindaddr *\n");
		f.close();
	}

	let f = fs.open("/tmp/radius.servers", "w");
	if (f) {
		f.write(sprintf("%s %s\n", server, secret));
		f.close();
	}
	return system(['/usr/sbin/radiusprobe']);
}

for (let iface in interfaces) {
	let name = iface.interface;
	if (name == "loopback")
		continue;

	count++;

	let health = {};
	let ssid = {};
	let radius = {};
	let device = iface.l3_device;
	let warnings = [];

	let dns = iface["dns-server"];
	if (!length(dns) && iface["ipv4-address"] && iface["ipv4-address"][0])
		dns = [ iface["ipv4-address"][0]["address"] ];

	for (let ip in dns) {
		let rc = system(['/usr/sbin/dnsprobe', '-s', ip]);

		if (rc) {
			health.dns = false;
			push(warnings, sprintf("DNS %s is not reachable", ip));
		}
	}


	for (let k, iface in wifi_config) {
		if (iface[".type"] != "wifi-iface" || iface.network != name)
			continue;
		if (find_ssid(iface.ssid))
			ssid[iface.ssid] = false;
		if (iface.auth_server && iface.auth_port && iface.auth_secret && !iface.radius_gw_proxy)
			if (radius_probe(iface.auth_server, iface.auth_port, iface.auth_secret)) {
				radius[iface.ssid] = false;
				push(warnings, sprintf("Radius %s:%s is not reachable", iface.auth_server, iface.auth_port));
			}
	}

	if (length(ssid))
		health.ssids = ssid;

	if (length(radius))
		health.radius = radius;

	if (length(health)) {
		health.location= cursor.get("network", name, "ucentral_path");
		if (length(warnings))
			health.warning = warnings;
		state.interfaces[name] = health;
	}
}

try {
	memory = ctx.call("system", "info");
	memory = memory.memory;
	state.unit.memory =  100 - (memory.available * 100 / memory.total);
}
catch(e) {
	log("Failed to invoke memory probing: %s\n", e);
}

let errors = length(state.interfaces);
if (!errors)
	delete state.interfaces;

let sanity = 100 - (errors * 100 / count);

warn(printf("health check reports sanity of %d", sanity));
ctx.call("ucentral", "health", {sanity: sanity, data: state});
