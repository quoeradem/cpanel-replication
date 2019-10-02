cpanel-replication
====
Provides hooks to replicate WHM/cPanel API functions between nodes.

**Note:** This project was a conceptual demonstration developed as part of an experiment to provide high-availability for servers running cPanel. While the replication works as intended it is currently missing features such as logging, error handling, etc. As such, this probably shouldn't be used in production.

### Installation
This script is intended for master-slave topologies and should only be installed on the master node. Please ensure that the master node is allowing outbound TCP traffic on ports **2083** and **2087**.

1. Copy the module to the cPanel include location and create the configuration files:
    ```
    # cp CpanelReplication.pm /usr/local/cpanel/
    # touch /etc/cprepl.d/{authkeys,events,remote_hosts}
    ```

2. Update [configuration](#Configuration) files. This **must** be performed before the hooks are registered in the next step.

3. Register hooks:
    ```
    # /usr/local/cpanel/bin/manage_hooks add module CpanelReplication
    ```

### Configuration
- `/etc/cprepl.d/authkeys` - Secondary node's WHM API token. The API token can be generated in WHM (_Home » Development » Manage API Tokens_).
- `/etc/cprepl.d/events` - Newline separated list of hookable events to replicate. A sample list of events is included in `events`. See the [cPanel Developer Documentation](https://documentation.cpanel.net/display/DD/Developer+Documentation+Home) for details on each event.
- `/etc/cprepl.d/remote_hosts` - IP of secondary node.

**Example configuration**
```
# cat /etc/cprepl.d/remote_hosts
127.0.0.1

# cat /etc/cprepl.d/authkeys
ZC82I103UORW7ZCCKDBH86PFSEAEG4PW

# cat /etc/cprepl.d/events
Cpanel/UAPI::Email::add_pop
Cpanel/UAPI::Ftp::add_ftp
```

### Removal
Individual hooks can be managed and removed in WHM (_Home » Development » Manage Hooks_).

Alternatively, the following command can be used to remove all hooks created by the _CpanelReplication_ module:
```
# while read -a HOOK; do whmapi1 delete_hook id=$HOOK; done < <(whmapi1 list_hooks | awk 'h{print $2;h=0} /CpanelReplication::/{h=1}')
```

License
-------
This project is licensed under The MIT License (MIT). A copy of this license has been included in `LICENSE`.