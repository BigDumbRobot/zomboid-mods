#!/usr/bin/env python3
# Writes media/scripts/Whisperers_Mannequins.txt: one head-stake mannequin per
# vanilla skin. Keep the skin list in step with S.Skins in Whisperers_Stake.lua
# (the tester's whisperers_gear_checks.lua checks the two agree).
#   python3 tools/gen_mannequins.py
import os
here = os.path.dirname(os.path.abspath(__file__))
out_path = os.path.join(here, '..', 'Contents/mods/TheWhisperers/42/media/scripts/Whisperers_Mannequins.txt')
male = ['MaleBody0%d%s' % (i, s) for s in ('', 'a') for i in range(1, 6)]
female = ['FemaleBody0%d' % i for i in range(1, 6)]
for g, lst in (('M', male), ('F', female)):
    for i in range(1, 5):
        lst.append('%s_ZedBody0%d' % (g, i))
        lst += ['%s_ZedBody0%d_level%d' % (g, i, l) for l in range(1, 4)]
out = ['/************************************************************',
       ' * The Whisperers: head stake mannequins, one per vanilla skin.',
       ' *',
       ' * A mannequin takes its skin from its script, so each skin a',
       ' * stake can show needs its own entry. Poses keep the neck over',
       ' * the pelvis so the stick stands straight. Generated: keep the',
       ' * list in step with Whisperers_Stake.lua.',
       ' ************************************************************/',
       '', 'module Base', '{']
for female_, lst in ((False, male), (True, female)):
    for tex in lst:
        out += ['    mannequin Whisp_Stake_%s' % tex, '    {',
                '        female = %s,' % ('true' if female_ else 'false'),
                '        model = %s,' % ('FemaleBody' if female_ else 'MaleBody'),
                '        texture = %s,' % tex,
                '        animSet = mannequin,',
                '        animState = %s,' % ('female' if female_ else 'male'),
                '        pose = %s,' % ('pose01' if female_ else 'pose03'),
                '        outfit = none,', '    }', '']
out[-1:] = ['}']
open(out_path, 'w').write('\n'.join(out) + '\n')
print('wrote', len(male) + len(female), 'mannequins to', os.path.normpath(out_path))
