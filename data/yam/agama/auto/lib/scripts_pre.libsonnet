{
  activate_multipath: {
    name: 'activate multipath',
    content: |||
      #!/bin/bash
      if ! systemctl status multpathd ; then
        echo 'Activating multipath'
        systemctl start multipathd.socket
        systemctl start multipathd
      fi
    |||
  },
  download_file: {
    name: 'download file',
    content: |||
      #!/usr/bin/env bash
      mkdir /files
      cd /files
      curl -skO https://raw.githubusercontent.com/os-autoinst/os-autoinst-distri-opensuse/master/data/yam/autoyast/dummy.xml
    |||
  },
  wipe_filesystem: {
    name: 'wipefs',
    content: |||
      #!/usr/bin/env bash
      for i in `lsblk -n -l -o NAME -d -e 7,11,254`
          do wipefs -af /dev/$i
          sleep 1
          sync
      done
    |||
  },
  disable_questions: {
    name: 'disable questions',
    content: |||
      #!/usr/bin/env bash
      agama questions mode non-interactive
    |||
  },
}
