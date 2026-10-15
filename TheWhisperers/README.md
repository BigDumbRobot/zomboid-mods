# The Whisperers

A Project Zomboid Build 42 (42.20+) mod inspired by the Whisperers from *The Walking Dead*. Blood and gore on your body and clothing hide you from zombies, as long as you stay low and quiet.

## Behavior

- **Gore** is the share of your body covered in blood, counting skin and worn clothing (whichever is bloodier per body part), plus a little from your equipped weapon.
- **Camouflage** turns on at `MinGorePercent` (25% by default) and reaches full strength at `FullGorePercent` (70%).
- **Whisper meter** (0–100%) is shown while camouflaged. It rises at most `MeterRiseRate`%/s, and after `MeterFallDelay` (2) seconds of quiet it falls at `MeterFallRate` (4)%/s.
  - It only rises while a zombie is within `MeterZombieRadius` (8) tiles. With none that close you can walk upright, run or make noise freely, and the meter falls.
  - Posture pulls it toward a level: crouched and still is 0, sneak-walking 10, standing upright 55, walking upright 70, running 85, sprinting (or sitting in a car with the engine running) 100.
  - Noise adds to it: each melee swing adds 25 (`MeleeNoise`), plus hits, gunshots and any world sound you make. Gore muffles small noises. Melee swings, gunshots and shouts get through at nearly full strength.
- **Stealth hierarchy: guts < face mask < skin suit.** Guts give camouflage. Worn dead skin adds **cover** on top: an intact mask gives 35% (`MaskCover`), an intact suit 65% (`SuitCover`), and both together 100%. Cover is scaled by camouflage strength and affects everything:
  - **How fast stealth kicks in:** the meter falls faster with the square of cover, up to 50× at full cover (`CoverFallBoost`), and the pause before it falls shrinks to nothing. Crouching from 70% takes about 20 s to settle with guts alone, about 4 s in a mask, about 1.5 s in a suit, and is instant in both. Cover also slows the rise by up to 40%.
  - **How much stealth:** postures ease toward the full-disguise levels by the cover. Those are standing 10, walking 30, running 35 and sprinting 60 (`DisguisedStillLevel`, `DisguisedWalkLevel`, `DisguisedRunLevel`, `DisguisedSprintLevel`). Cover muffles small noises by up to 60% more and loud ones by up to 30%.
  - **Zombie reaction:** zombies notice you at 50%, raised by up to 40 points with cover (`CoverNoticeBonus`): 64% in a mask, 76% in a suit, 90% in both. Cover also halves the notice radius at most, and zombies after you give up up to twice as fast. Fully disguised, you can walk, run and even sprint among the dead unnoticed. It takes something drastic like a gunshot to give you away.
- **Zombie awareness**
  - Below your notice level (50%, higher with cover): zombies take you for one of their own and no new ones come for you. Zombies already after you lose interest gradually: half of them give up within `InterestHalfLife` seconds (10) just under your notice level, and faster as the meter falls (a quarter of that at 0%). A zombie that fixes on you stands idle, deaf and blind, until you walk away or get loud. So does one walking to within 6 tiles of you without a target, such as one following your footsteps or heading for where it last saw you. It isn't held if another player who can be seen is within `FullAlertRadius`, because a held zombie can't see anyone.
  - At your notice level and above: zombies within a radius that grows with the meter (`AttractRadiusMin` to `AttractRadiusMax`) notice you and come for you.
  - 100%: every zombie within `FullAlertRadius` comes for you.
  - Vanilla sound attraction still works. A gunshot draws zombies to where it was fired whatever the meter shows.
- **Misery**: while any blood remains on your skin, worn clothing, or any weapon in your main inventory, unhappiness and stress climb (up to their caps) and discomfort is held high. Hemophobic characters suffer twice as fast. Wash everything to recover.
  - Discomfort and corpse sickness are held every tick, like vanilla's own corpse sickness, so the Uncomfortable and Sick moodles stay steady. Corpse sickness is vanilla food sickness: it drains away normally once you're clean.

## Wearing the dead

Right-click a human corpse and open the **Whisperer** submenu.

- **Butcher for Guts** needs a blade that can butcher animals and takes as long as butchering an animal on the ground (900 − 20 × Butchering). It yields 2 + 0.5 per Butchering level guts at 2.5 kg each.
  - **Rot:** guts halve in weight and capacity every 72 in-game hours (`GutsHalfLifeHours`) and rot away below 5%.
  - **Carrying:** more than 5 kg of guts keeps you uncomfortable and slowly sickens you.
- **Smear Guts on Yourself** (inventory or ground) spreads 75% of a gut's remaining capacity evenly over every body part and worn garment. The rest is wasted. Smeared guts cause corpse sickness (the vanilla SICKNESS stat, reduced by vanilla corpse-sickness defense), scaled by how much of you is covered, until you wash.
  - **Smear All Guts on Yourself** uses every gut you carry, freshest first, and stops once camouflage is at full strength (gore at `FullGorePercent`, 70% by default). Guts alone can take gore to 90%, since each body part holds at most full blood.
- **Remove Head** lists every eligible weapon you carry, including ones in bags.
  - Swords and katanas take one blow.
  - Long blades take 6 chops and axes 5, one fewer per 3 Butchering levels (minimum 2). Both chop straight down.
  - Short blades take 24 stabs, one fewer per Butchering level (minimum 8). They stab straight down, and every stab costs endurance.
  - The head is named **Zombie Head** or **<Player>'s Head**.
- **Cut Off Face** (right-click the head) needs a short blade. Butchering and sharpness shorten the job and reduce damage. At Butchering 10 with a keen edge the face comes off whole. You keep the head, marked "(Faceless)".
- **Face masks keep their face.** A mask is the face it was cut from, as a 3D mask over the wearer's own face: a rotting zombie's face, or a player's. Every mask face is stretched, sagging and mutilated (grey dead skin on human faces, hollow eyes, cuts, blood, a crudely stitched edge). Masks from before 1.1.0 show a zombie face.
- **Sew Face Mask** is a crafting recipe that needs Tailoring 3 and Butchering 3: the face, plus 2 thread, twine or fishing line, 4 dental floss, or 1 wire, plus a needle, suture needle or nail.
  - A nail costs the mask 30% condition.
  - A worn mask multiplies your gore ×5.
  - Looking out through the eye holes blurs everything more than 3 tiles away, like going without your glasses (`MaskVisionBlur`, `MaskClearRadius`). It uses the vanilla foraging overlay, and foraging takes the overlay over while it's on.
  - Putting it on or taking it off costs 10% condition, and it wears down while worn.
  - It can tear apart at any time, more likely as it wears. A torn mask gives no bonus.
  - Repair needs Tailoring 5 and the same materials, and takes as long as repairing a garment.
- **Remove Brain** (crafting) needs a knife or cleaver and uses up the head, with or without its face. The brain (**Zombie Brain** or **<Player>'s Brain**) works like an animal brain in vanilla **Make Bowl of Brain Tan**, and can be eaten (see below).
- **Make Head Stake** (crafting) combines any head with a long stick. Right-click it and choose **Place** to set it down like furniture (it picks back up the same way). The stake shows a 3D head with the face and hair it had when it was cut off, zombie or player. Heads taken before 1.1.0 get a random face (a human one for player heads), and a faceless head is flayed. A hat or mask can go on it. Like furniture, people and cars can't pass through it.
  - **Disassemble Head Stake** (crafting) gives back the head and the long stick, but each has a 75% chance to break (`HeadStakeBreakChance`). A surviving head keeps its name and stays faceless if it was. A placed stake must be picked up first.
- **Skin into a Suit** needs Tailoring 4, Butchering 3, a butchering blade, a sewing tool, and three masks' worth of clasp material. Nothing of the body is left (its belongings drop to the ground), so take the head and guts first. A headless corpse can still be butchered and skinned.
  - A worn suit multiplies your gore ×10 and strips all clothing except head gear, shoes and socks. Nothing but those and bags can be worn over it.
  - It wears like a mask. Hits wear it down, and a single hit of 20+ damage tears it apart.
- **Zombie mannerisms:** in an intact face mask *and* skin suit you move like a zombie (`ZombieMannerisms`). Either piece alone, or a torn one, leaves you moving as a human. The animations are vanilla zombie clips, and speed comes from the clip:
  - Standing: the zombie idle sway. Sitting on the ground: slumped like a zombie against a wall.
  - Walking, and crouch-walking: the zombie shamble (about 65% of a normal walk). Crouching keeps its quiet footsteps and its hold on the meter.
  - Crouch-running: a quicker shamble.
  - Running: the attacking zombie's arms-out lunge (about half a normal run).
  - Sprinting: a sprinter zombie's run, at a sprinter's speed (about 70% of a normal sprint).
  - Everything else stays human: turning on the spot, aiming, fighting, climbing, carrying corpses, timed actions and idle fidgets. Held weapons are carried in zombie poses, so they can look odd.
  - Other players see it too: every client sets it on every player from what they wear.
- **Drying:** dead skin dries out whether worn or not. An untreated face mask or skin suit loses half its condition every 168 in-game hours (`GearDryHalfLifeHours`) and crumbles below 5%. Gear left in a container catches up when it's carried again.
  - **Treat with Brain Tan** (crafting, not while worn) works a vanilla **Bowl of Brain Tan** into the mask or suit. It stops drying for 336 hours (`GearTreatHours`), shows "(Treated)" in the name, and gives the bowl back. Treating again restarts the clock. Zombie brains make brain tan.
- **Eating a brain:**
  - A zombie's brain gives you the Knox virus (following the sandbox Transmission setting) and 40% food sickness (`ZombieBrainSickness`).
  - A player's brain teaches you one level (`PlayerBrainLevels`) in every skill they had at level 6 or higher (`PlayerBrainMinSkill`), never past 10. Their skills are remembered while they're alive and travel with the corpse, head, stake and brain.

Player corpses are recognised by their name, which the mod keeps on each living player. B42 copies it onto the corpse.

### Placeholder art

These reuse vanilla assets until custom art exists:

- **Mask:** the hide hockey mask.
- **Suit:** the zombie body texture, painted on like vanilla `Zed_Skin`. It uses the male texture for everyone.
- **Head:** the human skull.
- **Head Stake:** the pig-skull pole sprites.
- **Guts:** the fish-guts model.
- **Beheaded corpses:** the corpse wears a hidden neck-stump item (built like vanilla's ZedDmg wound items) whose clothing mask hides the head, with a vanilla neck-wound decal and blood. It never shows in the loot window and can't be taken or worn.

## Multiplayer

Each client runs its own meter and sends it to the server about once a second. The server applies the misery to player stats and relays the meter to every client. Zombie control runs on whichever client simulates that zombie, so it works for other players' meters too.

## Install

Enable mod ID `TheWhisperers`. All tuning is in **Sandbox → The Whisperers**.

## HUD

The meter appears above the hotbar while you are camouflaged, or while it is still draining. Drag it to move it; its position is saved per character.

## Testing

The mod ships no test code. Its tests live in lilBubby's Big ol Mod Tester
(`~/Zomboid/Workshop/LilBubbyModTester`):

- In game: right-click → **Open Mod Showcase** → **The Whisperers**, or **Run every test**.
- Offline: from that project, `lua tests/whisperers_meter_checks.lua`,
  `lua tests/whisperers_gear_checks.lua`, `lua tests/whisperers_gait_checks.lua` and
  `lua tests/whisperers_suite_checks.lua`. The first three run this mod's real code: its Workshop subscription once published,
  otherwise this project folder.

## Tools

`tools/` holds the scripts that build the head stake's assets: the stick model, the flayed-face texture, the mannequin scripts and the tile properties. See `tools/README.md`. They are outside `Contents/`, so they are never uploaded. Tests live in LilBubbyModTester.
