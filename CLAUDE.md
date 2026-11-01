# mCLEAN — contexte projet

App macOS personnelle de barre de menus, version perso de Memory Cleaner (AppYogi) : mémoire disponible en direct, détail (applis, résidente, compressée, cache, libre), pression, swap, nettoyage en un clic, nettoyage profond, nettoyage automatique sous un seuil, applis inactives (notification, bouton Quitter).

## Architecture
- `Sources/MCleanCore` : logique sans AppKit (relevé Mach/sysctl, calculs, limites de nettoyage, réglages, règles auto/inactif). Toute logique testable va ici.
- `Sources/mCLEAN` : app AppKit + SwiftUI (`LSUIElement`), thème Socle (`Socle.swift` recopié par `build.sh`). `AppModel` (état), `AppDelegate` (icône de barre de menus, panneau), `PanelView`, `SettingsView`, `Notifier`, `About`.
- Nettoyage : alloue des pages par paliers de 0,5 Go (`mmap`) pour pousser le cache de fichiers hors de la RAM, libère, s'arrête dès pression ≠ normale, swap/compression en hausse, réserve de 2 Go ou durée max. « Profond » ajoute `purge` (mot de passe via osascript) et vise aussi 25 % de la mémoire des applis.
- Empreinte par appli : `proc_pid_rusage` cumulée sur le processus responsable.
- Réglages : JSON dans UserDefaults (`AppSettings`, décodage tolérant).

## Commandes
- Tests : `swift test` (16 tests). App : `./build.sh` → `~/Applications/Home Applications/mCLEAN.app` (signé via `sign_app.sh`).
- Essais réels : `SELFTEST=1 ./build.sh` puis `build/mCLEAN.app/Contents/MacOS/mCLEAN --selftest status|clean|deep|render <dossier>`.
- Langues : `tools/strings_table.py` → `python3 tools/gen_strings.py`. Icône : `assets/make_icon.py` (PyQt6, `QT_QPA_PLATFORM=offscreen`).
- Couleur du logo (« m » du nom) : vert #34D399 (`Brand`).

## Points ouverts
- Nettoyage profond (`purge`) non testé en réel (mot de passe administrateur requis).
- Notifications et ouverture à la connexion non testées en réel dans l'app seule.
- Pas de dépôt GitHub créé (création refusée par le classifieur le 01/11/2026).
