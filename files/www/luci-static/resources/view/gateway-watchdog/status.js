'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var statusRpc = rpc.declare({
    object: 'gateway-watchdog-status',
    method: 'get_status'
});

return view.extend({
    load: function() {
        return statusRpc().then(function(res) {
            return res;
        }).catch(function(err) {
            console.error("Error reading status:", err);
            return {};
        });
    },

    render: function(initialData) {
        var self = this;
        var container = E('div', { 'class': 'cbi-section' });

        if (!document.querySelector('#gateway-watchdog-styles')) {
            var style = document.createElement('style');
            style.id = 'gateway-watchdog-styles';
            style.textContent = `
                .metrics-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                    gap: 1rem;
                    margin-bottom: 2rem;
                }
                .metric-card {
                    background: #2a2a2a;
                    border-radius: 8px;
                    padding: 1rem;
                    text-align: center;
                    border: 1px solid #444;
                }
                .metric-label {
                    font-size: 14px;
                    color: #aaa;
                    margin-bottom: 8px;
                }
                .metric-value {
                    font-size: 28px;
                    font-weight: bold;
                    color: #fff;
                    word-break: break-word;
                    line-height: 1.3;
                }
                .history-table {
                    width: 100%;
                    border-collapse: collapse;
                    background: #1e1e1e;
                    color: #f0f0f0;
                }
                .history-table th,
                .history-table td {
                    padding: 8px 12px;
                    text-align: left;
                    border-bottom: 1px solid #333;
                }
                .history-table th {
                    background: #2a2a2a;
                    color: #ccc;
                    font-weight: bold;
                }
                .history-table tr:hover {
                    background: #2a2a2a;
                }
                .status-healthy {
                    color: #4caf50;
                    font-weight: bold;
                }
                .status-unhealthy {
                    color: #ff9800;
                    font-weight: bold;
                }
                .status-recovering {
                    color: #9c27b0;
                    font-weight: bold;
                }
                .status-cable_disconnected {
                    color: #757575;
                    font-weight: bold;
                }
                .status-unknown {
                    color: #f0f0f0;
                    font-weight: bold;
                }
                .sort-select {
                    width: 200px;
                    padding: 8px;
                    margin-bottom: 15px;
                    background: #2a2a2a;
                    border: 1px solid #444;
                    color: #f0f0f0;
                    border-radius: 4px;
                }
            `;
            document.head.appendChild(style);
        }

        var metricsContainer = E('div', { 'class': 'metrics-grid' });
        this.metricElements = {};

        var metrics = [
            { key: 'total_checks', label: 'Total Checks' },
            { key: 'total_failures', label: 'Total Failures' },
            { key: 'total_recoveries', label: 'Total Recoveries' },
            { key: 'consecutive_failures', label: 'Consecutive Failures' },
            { key: 'last_loop_time', label: 'Last Check' }
        ];

        for (var i = 0; i < metrics.length; i++) {
            var card = E('div', { 'class': 'metric-card' });
            card.appendChild(E('div', { 'class': 'metric-label' }, metrics[i].label));
            var valueSpan = E('div', { 'class': 'metric-value' }, '--');
            card.appendChild(valueSpan);
            metricsContainer.appendChild(card);
            this.metricElements[metrics[i].key] = valueSpan;
        }

        var sortSelect = E('select', { 'class': 'sort-select' });
        var sortOptions = [
            { value: 'date-desc', label: 'Sort by Date (newest first)' },
            { value: 'checks-desc', label: 'Sort by Checks (highest first)' },
            { value: 'failures-desc', label: 'Sort by Failures (highest first)' },
            { value: 'recoveries-desc', label: 'Sort by Recoveries (highest first)' },
            { value: 'event-asc', label: 'Sort by Event (A-Z)' }
        ];
        for (var o = 0; o < sortOptions.length; o++) {
            var opt = document.createElement('option');
            opt.value = sortOptions[o].value;
            opt.textContent = sortOptions[o].label;
            sortSelect.appendChild(opt);
        }

        var historyHeading = E('h3', { style: 'color: #fff; margin: 20px 0 10px;' }, 'Recent Events (last 10)');
        var historyTable = E('table', { 'class': 'history-table' });

        var thead = document.createElement('thead');
        var headerRow = E('tr');
        var headers = ['Date', 'Checks', 'Failures', 'Recoveries', 'Status', 'Event'];
        for (var h = 0; h < headers.length; h++) {
            headerRow.appendChild(E('th', {}, headers[h]));
        }
        thead.appendChild(headerRow);
        historyTable.appendChild(thead);

        var tbody = document.createElement('tbody');
        historyTable.appendChild(tbody);
        this.historyBody = tbody;

        container.appendChild(metricsContainer);
        container.appendChild(sortSelect);
        container.appendChild(historyHeading);
        container.appendChild(historyTable);

        this.rawHistory = [];
        this.currentSort = 'date-desc';

        this.sortHistory = function() {
            var sorted = this.rawHistory.slice();
            switch (this.currentSort) {
                case 'date-desc':
                    sorted.sort(function(a, b) {
                        return b.date.localeCompare(a.date);
                    });
                    break;
                case 'checks-desc':
                    sorted.sort(function(a, b) {
                        return parseInt(b.checks) - parseInt(a.checks);
                    });
                    break;
                case 'failures-desc':
                    sorted.sort(function(a, b) {
                        return parseInt(b.failures) - parseInt(a.failures);
                    });
                    break;
                case 'recoveries-desc':
                    sorted.sort(function(a, b) {
                        return parseInt(b.recoveries) - parseInt(a.recoveries);
                    });
                    break;
                case 'event-asc':
                    sorted.sort(function(a, b) {
                        return a.event.localeCompare(b.event);
                    });
                    break;
                default:
                    sorted.sort(function(a, b) {
                        return b.date.localeCompare(a.date);
                    });
            }
            return sorted;
        }.bind(this);

        this.renderHistory = function() {
            if (!this.rawHistory) return;
            var sorted = this.sortHistory();
            this.historyBody.innerHTML = '';
            for (var i = 0; i < sorted.length; i++) {
                var entry = sorted[i];
                var row = E('tr');
                row.appendChild(E('td', {}, entry.date));
                row.appendChild(E('td', {}, entry.checks));
                row.appendChild(E('td', {}, entry.failures));
                row.appendChild(E('td', {}, entry.recoveries));
                var statusCell = E('td', {}, entry.status);
                var statusClass = 'status-unknown';
                if (entry.status === 'healthy') statusClass = 'status-healthy';
                else if (entry.status === 'unhealthy') statusClass = 'status-unhealthy';
                else if (entry.status === 'recovering') statusClass = 'status-recovering';
                else if (entry.status === 'cable_disconnected') statusClass = 'status-cable_disconnected';
                statusCell.classList.add(statusClass);
                row.appendChild(statusCell);
                row.appendChild(E('td', {}, entry.event));
                this.historyBody.appendChild(row);
            }
        }.bind(this);

        sortSelect.addEventListener('change', function(e) {
            this.currentSort = e.target.value;
            this.renderHistory();
        }.bind(this));

        this.updateUI(initialData);

        // Poll every 5 seconds
        poll.add(function() {
            return statusRpc().then(function(res) {
                self.updateUI(res);
            }).catch(function(err) {
                console.error("Poll error:", err);
            });
        }, 5);

        return container;
    },

    updateUI: function(data) {
        if (!data) return;

        for (var key in this.metricElements) {
            var val = data[key] !== undefined ? data[key] : 'N/A';
            if (key === 'last_loop_time' && val !== 'N/A') {
                val = new Date(parseInt(val) * 1000).toLocaleString();
            }
            this.metricElements[key].textContent = val;
        }

        this.rawHistory = [];
        if (data.history && Array.isArray(data.history)) {
            for (var i = 0; i < data.history.length; i++) {
                var line = data.history[i];
                var parts = line.split('|');
                if (parts.length >= 7) {
                    this.rawHistory.push({
                        date: parts[1],
                        checks: parts[2],
                        failures: parts[3],
                        recoveries: parts[4],
                        status: parts[5],
                        event: parts[6]
                    });
                }
            }
        }
        this.renderHistory();
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
