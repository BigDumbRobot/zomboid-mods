#!/usr/bin/env python3
# Sets the head stake tile properties in whisperers_headstake.tiles:
#   _0     the mannequin tile the 3D stakes place as (CustomName must be exactly
#          "Mannequin" for the game to treat it as one)
#   _1..3  the old flat stakes, kept for saves that still have them
# Every tile is solidtrans, like furniture, so people and cars can't pass.
#   python3 tools/set_stake_tiles.py
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import tiles
path = os.path.join(here, '..', 'Contents/mods/TheWhisperers/42/media/whisperers_headstake.tiles')
ver, sets = tiles.parse(path)
stake = sets[0]['tiles']
stake[0] = [('BlocksPlacement', ''), ('ContainerPutSound', 'MannequinTransferItem'),
            ('ContainerTakeSound', 'MannequinTransferItem'), ('CustomItem', 'Whisperers.HeadStake'),
            ('CustomName', 'Mannequin'), ('GroupName', 'Whisperers'), ('IsMoveAble', ''),
            ('IsoType', 'IsoMannequin'), ('PickUpWeight', '20'), ('solidtrans', '')]
for facing, t in zip('NWE', stake[1:4]):
    stake[stake.index(t)] = [('BlocksPlacement', ''), ('CustomItem', 'Whisperers.HeadStake'),
        ('CustomName', 'Head Stake'), ('Facing', facing), ('GroupName', 'Whisperers'), ('IsLow', ''),
        ('IsMoveAble', ''), ('PickUpWeight', '20'), ('solidtrans', '')]
tiles.write(path, ver, sets)
print('updated', os.path.normpath(path))
