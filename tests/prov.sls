disk0 labeled:
  block.labeled:
    - name: /dev/loop0

disk0 partitioned:
  block.partioned:
    - name: /dev/loop0
    - partitions:
      - number: 1
      - number: 2
      - number: 3

disk1 labeled:
  block.labeled:
    - name: /dev/loop1

disk1 partitioned:
  block.partioned:
    - name: /dev/loop1
    - partitions:
      - number: 1
      - number: 2
      - number: 3

/dev/md0:
  raid.present:
    - level: 1
    - devices:
      - /dev/loop0p1
      - /dev/loop1p1
    - run: True

/dev/md1:
  raid.present:
    - level: 1
    - devices:
      - /dev/loop0p2
      - /dev/loop1p2
    - run: True

/dev/md2:
  raid.present:
    - level: 1
    - devices:
      - /dev/loop0p3
      - /dev/loop1p3
    - run: True
