================================================================================
  XEINORIA - SURVIE MAP - README
================================================================================

EN
--

This archive contains the XEINORIA survival world (overworld + Nether + End)
as used live on the XEINORIA Minecraft server.

License: CC BY-NC-SA 4.0 - see LICENSE.txt
Official download page: https://norath.fr/download
Original work URL (required for attribution): https://norath.fr/download

Archive layout (single Vanilla-ready world folder, Paper 26.1+ migration):

  xeinoria-survie-world/
    level.dat
    icon.png
    datapacks/
    data/minecraft/                  <- the 5 migrated dimension files +
                                        vanilla world data (maps, etc.)
    dimensions/minecraft/overworld/
    dimensions/minecraft/the_nether/
    dimensions/minecraft/the_end/

The world has been converted from the Paper unified "dimensions/" layout to
the official Vanilla 26.1+ layout, following the procedure documented at
https://docs.papermc.io/paper/migration/#to-vanilla :

  - Dimensions remain under dimensions/minecraft/<dim>/ (NOT split into
    DIM-1 / DIM1 at the world root, which is the pre-26.1 method).
  - Five files (game_rules.dat, scheduled_events.dat, wandering_trader.dat,
    weather.dat, world_gen_settings.dat) have been moved from the overworld
    dimension's data/minecraft/ folder into the world root's data/minecraft/.
  - Paper-specific files (data/paper/, paper-world.yml) have been removed.

Privacy:
  - Player data (advancements, inventories, statistics) is NOT included.
  - The scoreboard (data/minecraft/scoreboard.dat) is NOT included.

How to use this archive:

  1. Make sure your Minecraft client/server version matches the version
     listed in VERSION.txt (or use a Vanilla / Paper 26.1+ server).
  2. Unzip the archive somewhere. You get a single world folder.
  3. SELF-HOSTED VANILLA / PAPER 26.1+ SERVER:
       - Put xeinoria-survie-world/ into your server root.
       - Set  level-name=xeinoria-survie-world  in server.properties.
       - Start the server. Both Vanilla and Paper 26.1+ load the three
         dimensions automatically from dimensions/minecraft/.
  4. SINGLE-PLAYER SAVE (Vanilla 26.1+):
       - Copy xeinoria-survie-world/ into your .minecraft/saves/ folder.
       - Open the world from the singleplayer menu. The Nether and the
         End are loaded automatically from the dimensions/ subfolder.

By using this archive you agree to the LICENSE.txt terms.

FR
--

Cette archive contient le monde de survie XEINORIA (overworld + Nether + End)
tel qu'utilise en direct sur le serveur Minecraft XEINORIA.

Licence : CC BY-NC-SA 4.0 - voir LICENSE.txt
Page de telechargement officielle : https://norath.fr/download
URL de l'oeuvre originale (obligatoire pour l'attribution) :
  https://norath.fr/download

Contenu de l'archive (un seul dossier monde Vanilla, migration Paper 26.1+) :

  xeinoria-survie-world/
    level.dat
    icon.png
    datapacks/
    data/minecraft/                  <- les 5 fichiers migres depuis la
                                        dimension overworld + donnees
                                        vanilla globales (maps, etc.)
    dimensions/minecraft/overworld/
    dimensions/minecraft/the_nether/
    dimensions/minecraft/the_end/

Le monde a ete converti depuis le layout Paper unifie "dimensions/" vers
le layout officiel Vanilla 26.1+, en suivant la procedure officielle
https://docs.papermc.io/paper/migration/#to-vanilla :

  - Les dimensions restent sous dimensions/minecraft/<dim>/ (et NON
    splittees en DIM-1 / DIM1 a la racine, qui est la methode pre-26.1).
  - Cinq fichiers (game_rules.dat, scheduled_events.dat, wandering_trader.dat,
    weather.dat, world_gen_settings.dat) ont ete deplaces depuis
    dimensions/minecraft/overworld/data/minecraft/ vers data/minecraft/
    a la racine du monde.
  - Les fichiers specifiques Paper (data/paper/, paper-world.yml) ont
    ete retires.

Confidentialite :
  - Les donnees joueurs (advancements, inventaires, statistiques) ne sont
    PAS incluses.
  - Le scoreboard (data/minecraft/scoreboard.dat) n'est PAS inclus.

Comment utiliser cette archive :

  1. Assurez-vous que votre version de Minecraft correspond a la version
     indiquee dans VERSION.txt (ou utilisez un serveur Vanilla / Paper
     26.1 ou plus recent).
  2. Decompressez l'archive ou vous voulez. Vous obtenez un seul dossier.
  3. SERVEUR VANILLA / PAPER 26.1+ auto-heberge :
       - Placez xeinoria-survie-world/ a la racine de votre serveur.
       - Indiquez  level-name=xeinoria-survie-world  dans server.properties.
       - Demarrez le serveur. Vanilla et Paper 26.1+ chargent
         automatiquement les trois dimensions depuis dimensions/minecraft/.
  4. SAUVEGARDE SOLO (Vanilla 26.1+) :
       - Copiez xeinoria-survie-world/ dans votre dossier
         .minecraft/saves/  .
       - Ouvrez le monde depuis le menu solo. Le Nether et l'End sont
         charges automatiquement depuis le sous-dossier dimensions/.

En utilisant cette archive vous acceptez les termes de LICENSE.txt.

================================================================================
