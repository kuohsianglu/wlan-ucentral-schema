#!/usr/bin/ucode
push(REQUIRE_SEARCH_PATH,
	"/usr/lib/ucode/*.so",
	"/usr/share/ucentral/*.uc");

let schemareader = require("schemareader");
let renderer = require("renderer");
let fs = require("fs");

function is_online() {
	system("/usr/bin/ucode -l uci -l fs /usr/share/ucentral/onlinecheck.uc > /dev/null");

	let online_state = fs.open("/tmp/onlinecheck.state", "r");
	if (!online_state)
		return true;

	let ostate = json(online_state.read("all"));
	online_state.close();

	if (!ostate.online)
		return false;
	return true;
}

function is_raspberryPi() {
	let boardfile = fs.open("/etc/board.json", "r");
	let board = json(boardfile.read("all"));
	boardfile.close();

	let is_pi = match(board.model.name, /Raspberry*/);

	if(is_pi)
		return true;
	return false;
}

function eth0_phy_up() {
	let eth0_oper = fs.open("/sys/class/net/eth0/operstate", "r");
	let eth0_state = eth0_oper.read("all");
	eth0_oper.close();

	if(split(eth0_state, '\n')[0] == "down")
		return false;
	return true;
}

function ucfg_file() {
	let cfg_file = ARGV[0];

	if (is_raspberryPi() && !eth0_phy_up())
		cfg_file = "/etc/ucentral/ucentral.cfg.0000000002";

	if (is_raspberryPi() && eth0_phy_up() && !is_online())
		cfg_file = "/etc/ucentral/ucentral.cfg.0000000003";

	return cfg_file;
}

function rpi_uci_batch() {
	let uci_pi = fs.open("/etc/ucentral/pibatch", "r");
	let uci_batch = uci_pi.read("all");
	uci_pi.close();

	return uci_batch;
}

let inputfile = fs.open(ucfg_file(), "r");
let inputjson = json(inputfile.read("all"));
let custom_config = (split(ARGV[0], ".")[0] != "/etc/ucentral/ucentral");

let error = 0;

inputfile.close();
let logs = [];

function set_service_state(state) {
	for (let service, enable in renderer.services_state()) {
		if (enable != state)
			continue;
		printf("%s %s\n", service, enable ? "starting" : "stopping");
		system(sprintf("/etc/init.d/%s %s", service, enable ? "start" : "stop"));
	}
	system("/etc/init.d/ucentral-wifi restart");
	system("/etc/init.d/dnsmasq restart");
}

try {
	for (let cmd in [ 'rm -rf /tmp/ucentral',
			  'mkdir /tmp/ucentral',
			  'rm /tmp/dnsmasq.conf',
			  '/etc/init.d/uhealth stop',
			  'touch /tmp/ucentral.health',
			  'touch /tmp/dnsmasq.conf' ])
		system(cmd);

	let state = schemareader.validate(inputjson, logs);

	let batch = state ? renderer.render(state, logs) : "";

	fs.stdout.write("Log messages:\n" + join("\n", logs) + "\n\n");

	fs.stdout.write("UCI batch output:\n" + batch + "\n");

	if (state) {
		let outputjson = fs.open("/tmp/ucentral.uci", "w");
		outputjson.write(batch);
		outputjson.close();

		for (let cmd in [ 'rm -rf /tmp/config-shadow',
				  'cp -r /etc/config-shadow /tmp' ])
			system(cmd);

		let apply = fs.popen("/sbin/uci -c /tmp/config-shadow batch", "w");
		apply.write(batch);
		apply.close();

		if (is_raspberryPi() && eth0_phy_up()) {
			let apply_rpi = fs.popen("/sbin/uci -c /tmp/config-shadow batch", "w");
			let rpi_batch = rpi_uci_batch();
			fs.stdout.write("RPI UCI batch output:\n" + rpi_batch + "\n");
			apply_rpi.write(rpi_batch);
			apply_rpi.close();
		}

		renderer.write_files(logs);

		set_service_state(false);

		for (let cmd in [ 'uci -c /tmp/config-shadow commit',
				  'cp /tmp/config-shadow/* /etc/config/',
				  'rm -rf /tmp/config-shadow',
				  'wifi',
				  'reload_config',
				  '/etc/init.d/dnsmasq restart'])
			system(cmd);

		if (!custom_config) {
			fs.unlink('/etc/ucentral/ucentral.active');
			fs.symlink(ucfg_file(), '/etc/ucentral/ucentral.active');
		}

		set_service_state(true);
	} else {
		error = 1;
	}
	if (!length(batch))
		error = 2;
	else if (length(logs))
		error = 1;
}
catch (e) {
	error = 2;
	warn("Fatal error while generating UCI: ", e, "\n", e.stacktrace[0].context, "\n");
}

let ubus = require("ubus").connect();

if (inputjson.uuid && inputjson.uuid > 1 && !custom_config) {
	let status = {
		error,
		text: error ? "Failed" : "Success",
	};
	if (length(logs))
		status.rejected = logs;

	ubus.call("ucentral", "result", {
		uuid: inputjson.uuid || 0,
		id: +ARGV[1] || 0,
		status,
	});
}
