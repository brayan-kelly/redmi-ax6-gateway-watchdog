'use strict';
'require form';
'require uci';
'require view';
'require rpc';

var networkDevices = rpc.declare({
    object: 'luci-rpc',
    method: 'getNetworkDevices'
});

return view.extend({
    load: function() {
        var self = this;
        return Promise.all([
            uci.load('gateway_watchdog'),
            networkDevices()
        ]).then(function(results) {
            if (results[1] && results[1].devices) {
                self.interfaces = results[1].devices;
            } else {
                self.interfaces = [];
            }
        }).catch(function(err) {
            console.error("Failed to load config or interfaces:", err);
            self.interfaces = [];
        });
    },

    render: function() {
        var m, s, o;

        m = new form.Map('gateway_watchdog', _('Gateway Watchdog'),
            _('Monitor WAN connectivity and perform automatic recovery.'));

        s = m.section(form.NamedSection, 'settings', 'settings', _('General Settings'));
        s.anonymous = false;
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('Enable'));
        o.rmempty = false;
        o.default = '1';

        o = s.option(form.ListValue, 'interface', _('WAN Interface'));
        o.rmempty = false;
        o.default = 'wan';
        o.description = _('Network interface to monitor.');
        for (var i = 0; i < this.interfaces.length; i++) {
            var iface = this.interfaces[i];
            o.value(iface, iface);
        }
        var currentWan = uci.get('gateway_watchdog', 'settings', 'interface');
        if (currentWan && this.interfaces.indexOf(currentWan) === -1) {
            o.value(currentWan, currentWan + ' (custom)');
        }

        o = s.option(form.Value, 'delay', _('Check Interval (seconds)'));
        o.datatype = 'uinteger';
        o.rmempty = false;
        o.default = '10';

        o = s.option(form.Value, 'max_failures', _('Max Failures'));
        o.datatype = 'uinteger';
        o.rmempty = false;
        o.default = '5';

        o = s.option(form.Value, 'cooldown', _('Cooldown (seconds)'));
        o.datatype = 'uinteger';
        o.rmempty = false;
        o.default = '300';

        o = s.option(form.ListValue, 'recovery_mode', _('Recovery Mode'));
        o.rmempty = false;
        o.default = 'full';
        o.value('none', 'None');
        o.value('standard', 'Standard (ifdown/ifup)');
        o.value('dhcp-renew', 'DHCP Renew');
        o.value('lan-reset', 'LAN Reset (fix bridge/NAT issues)');
        o.value('full', 'Full (ifdown + dhcp-renew + lan-reset');
        o.value('reboot', 'Reboot');

        o = s.option(form.Value, 'recovery_verify_targets', _('Recovery Diagnostic Targets'));
        o.rmempty = false;
        o.default = '8.8.8.8,1.1.1.1';
        o.description = _('Comma-separated list of IPs to ping for connectivity verification.');

        o = s.option(form.Flag, 'log_to_console', _('Log to Console'));
        o.rmempty = false;
        o.default = '0';
        o.description = _('Also log to console (useful for debugging).');

        return m.render();
    }
});
