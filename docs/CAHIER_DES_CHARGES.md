# Trame — Cahier des charges

**Orchestrateur natif macOS de sessions Claude Code**

| | |
|---|---|
| Version | 1.1 — 29 juillet 2026 |
| Statut | Validé — tous les points de cadrage tranchés |
| Licence | Open source **MIT** (GitHub : `cldt-fr/trame`) |
| Plateforme | macOS (SwiftUI, app native) |

---

## 1. Vision

Trame est un cockpit natif macOS pour développeurs qui travaillent avec **plusieurs agents Claude Code en parallèle**. Il répond à trois douleurs :

1. **Le lancement et la configuration** : ouvrir N terminaux, configurer les `.mcp.json` à la main, gérer les worktrees git, dupliquer les clés API — tout cela est fastidieux et source d'erreurs.
2. **L'attention** : avec 5 sessions en parallèle, on ne sait jamais laquelle attend une permission, laquelle a terminé, laquelle est bloquée.
3. **La coordination** : faire communiquer des agents entre eux (via [claude-talkie-walkie](https://github.com/cldt-fr/claude-talkie-walkie)) demande aujourd'hui une configuration manuelle de ports, secrets et pairs.

**Proposition de valeur** : une seule fenêtre, hyper soignée, où l'on crée, surveille, review et interconnecte ses sessions Claude Code — sans jamais éditer un JSON à la main.

### Ce que Trame n'est pas

- Un IDE ni un éditeur de code (la review s'y fait, l'édition non).
- Un remplaçant des CLI d'agents : Trame **pilote** les outils officiels (Claude Code en V1, d'autres outils de code IA ensuite — cf. §4.4), il ne les réimplémente pas.
- Un service cloud : tout est local, aucune télémétrie.

---

## 2. Glossaire

| Terme | Définition |
|---|---|
| **Projet** | Un dépôt git enregistré dans Trame. |
| **Session** | Une instance de Claude Code attachée à un répertoire de travail : soit le repo lui-même, soit un **worktree** de ce repo. |
| **Worktree** | Checkout parallèle d'une branche du repo (`git worktree`), permettant plusieurs sessions simultanées sans conflits de fichiers. |
| **MCP** | Serveur Model Context Protocol attachable à une session. |
| **Profil MCP** | Ensemble nommé de MCPs applicable en un geste (ex. « Stack Web »). |
| **Mesh** | Réseau de communication entre sessions via talkie-walkie. |
| **Pair distant** | Instance Claude Code hors Trame (autre machine) participant au mesh. |
| **Inbox** | File centralisée des événements demandant l'attention de l'utilisateur. |
| **Compte** | Identité Anthropic (login Claude Code) enregistrée dans Trame ; chaque session s'exécute sous un compte. |
| **Adaptateur d'agent** | Couche qui isole les spécificités d'un outil de code IA (commande, hooks, transcripts, permissions). V1 : Claude Code uniquement. |

---

## 3. Décisions de cadrage (arbitrées)

| Sujet | Décision |
|---|---|
| Moteur | **Hybride** : V1 = CLI `claude` dans des terminaux PTY embarqués + chrome natif SwiftUI ; V2 = migration progressive vers l'Agent SDK pour les vues natives. |
| Modèle de session | 1 session = **repo ou worktree** ; création de worktree en un clic. |
| Orchestration | **Cockpit de supervision en V1** ; orchestration active (rôles, pipelines, session « chef ») en V2. |
| Distribution | **Open source**, distribution directe (hors Mac App Store), mises à jour via Sparkle. |
| MCPs | **Bibliothèque centrale + profils composables**, secrets dans le Keychain, health-check et logs par serveur. |
| Mesh | **Graphe interactif + auto-provisioning + inspecteur de messages + pairs distants** dès la V1. |
| Attention | **Inbox centralisée + notifications macOS actionnables + icône barre de menus avec mini-HUD**. |
| Design | **Natif macOS assumé** (type Things / Craft) : matériaux système, vibrancy, HIG, léger et aéré. |
| Git | **Review native + actions** : diff par session, commit, push, PR, merge de worktree. |
| Coûts | **Tracking par session + agrégats globaux** (jour/semaine), alertes de seuil. |
| Permissions | **Presets par session** (Prudent / Standard / Autonome) ; Autonome (skip-permissions) disponible partout, worktree recommandé avec avertissement renforcé hors worktree *(révisé le 29/07/2026)*. |
| Persistance | **Restauration complète** : les process survivent à la fermeture de la fenêtre ; sessions, mesh et inbox restaurés à la réouverture. |
| Comptes | **Multi-comptes Anthropic** : plusieurs comptes gérés dans Trame (un `CLAUDE_CONFIG_DIR` par compte), compte assigné par session, coûts ventilés par compte. |
| Extensibilité agents | **Claude Code seul en V1**, mais toute la logique spécifique au CLI est isolée derrière une **interface d'adaptateur d'agent** ; deuxième adaptateur pressenti : **Codex CLI** (V3). |
| Nommage | Noms de session **auto-générés** à la création (zéro friction), renommables ensuite ; rôle mesh dérivé mais renommable indépendamment. |
| Templates | **Défauts par projet dès la V1** (compte, profil MCP, preset ré-appliqués aux nouvelles sessions) ; templates nommés réutilisables en V2. |
| Push mobile | **Relais opt-in vers un service léger (ntfy/Pushover) en V1.1** pour les événements bloquants. |
| Licence | **MIT**. |

---

## 4. Architecture générale

### 4.1 Vue d'ensemble

```
┌─────────────────────────────────────────────────────┐
│  Trame.app (SwiftUI)                                │
│  Sidebar · Session View · Inbox · Mesh · MCP · Git  │
└───────────────▲─────────────────────────────────────┘
                │ XPC / IPC locale
┌───────────────┴─────────────────────────────────────┐
│  trame-core (agent d'arrière-plan, LaunchAgent)     │
│  · Possède les PTY des sessions `claude`            │
│  · Survit à la fermeture de la fenêtre              │
│  · Collecte hooks, transcripts JSONL, états         │
│  · Provisionne mesh talkie-walkie et .mcp.json      │
└───────┬───────────────┬───────────────┬─────────────┘
        │               │               │
   claude CLI      claude CLI      claude CLI
   (repo A)      (worktree A/1)     (repo B)
        └───── mesh talkie-walkie ─────┘  ⇄  pairs distants
```

### 4.2 Décision structurante : le démon `trame-core`

L'exigence « les sessions survivent à la fermeture de l'app » impose que les PTY ne soient **pas** possédés par le process de l'app. Trame installe donc un agent d'arrière-plan (`SMAppService` / LaunchAgent) qui :

- lance et possède les process `claude` (un PTY par session) ;
- bufferise la sortie terminal pour ré-attachement (scrollback persistant) ;
- expose une API locale (XPC) à laquelle l'UI s'attache/se détache ;
- reste vivant tant que des sessions tournent, s'éteint sinon.

L'UI est ainsi un simple client : la fermer, la relancer ou la faire crasher n'interrompt jamais un agent au travail.

### 4.3 Observation de l'état des sessions

Trame ne parse pas l'écran du terminal pour connaître l'état d'une session. Deux canaux fiables :

1. **Hooks Claude Code** : à la création d'une session, Trame injecte dans les settings du répertoire de travail des hooks (`Notification`, `Stop`, `PreToolUse`, `SessionStart`, …) qui notifient `trame-core` via HTTP local ou fichier. C'est le canal temps réel : « demande de permission », « question posée », « tâche terminée ».
2. **Transcripts JSONL** (`<CLAUDE_CONFIG_DIR>/projects/<slug>/*.jsonl` — un arbre par compte, cf. F9) : source de vérité pour l'historique, les tokens consommés, les coûts, les outils appelés. Lus en continu (file watcher) pour l'inbox, le tracking de coûts et le résumé d'activité.

### 4.4 Abstraction : les adaptateurs d'agent

Trame vise Claude Code en V1, mais l'ambition long terme est de piloter **n'importe quel outil de code IA en CLI** (Codex CLI, Gemini CLI, opencode, …). Pour ne pas payer une refonte plus tard, la règle d'architecture est posée dès la V0 :

**Rien dans `trame-core` ni dans l'UI ne parle directement au CLI `claude`.** Tout passe par une interface `AgentAdapter` qui couvre les points de variation entre outils :

| Responsabilité | Exemple Claude Code (V1) |
|---|---|
| Détection et version du CLI | `claude --version`, version minimale |
| Commande de lancement / reprise | `claude`, `claude --resume <id>` |
| Isolation de compte | `CLAUDE_CONFIG_DIR` |
| Configuration MCP | génération du `.mcp.json` |
| Événements temps réel | hooks (`Notification`, `Stop`, `PreToolUse`, …) |
| Historique / métriques | transcripts JSONL, tokens, coûts |
| Modes de permission | presets → flags/settings (`--dangerously-skip-permissions`, allowlists) |
| Capacités déclarées | mesh, resume, coûts, review — chaque adaptateur déclare ce qu'il sait faire |

Principes associés :

- **Capacités déclaratives** : l'UI s'adapte à ce que l'adaptateur déclare (un agent sans hooks temps réel aura une inbox dégradée par polling ; un agent sans notion de coût n'affiche pas F7). Aucune fonctionnalité n'est supposée universelle.
- **MCP comme dénominateur commun** : la bibliothèque MCP (F3) et le mesh talkie-walkie (F4) sont indépendants de l'agent — talkie-walkie étant un serveur MCP standard, un mesh mixte (session Claude Code ↔ session Codex) est possible dès lors que l'outil supporte MCP.
- **Anti-sur-abstraction** : l'interface est dimensionnée sur les besoins réels de Claude Code en V1 ; elle ne sera considérée comme stable qu'à l'implémentation du **deuxième** adaptateur, qui servira de test de validité.

### 4.5 Stack technique

| Composant | Choix | Notes |
|---|---|---|
| UI | SwiftUI (macOS 14+) | Matériaux natifs, vibrancy. |
| Terminal embarqué | SwiftTerm | Rendu du PTY, thème adapté à la DA. |
| Démon | Swift, `SMAppService` | Communication XPC avec l'app. |
| Git | CLI `git` (via Process) | Worktrees, diffs, commit, push ; pas de libgit2 en V1. |
| GitHub | CLI `gh` si présent | Création de PR ; dégradation gracieuse sinon. |
| Secrets | Keychain macOS | Clés API des MCPs, secret du mesh. |
| Persistance | SwiftData ou SQLite | Projets, sessions, MCPs, profils, historique de coûts. |
| Mises à jour | Sparkle | Distribution directe signée + notarisée. |
| Claude Code | CLI officiel, détecté sur la machine | Version minimale requise vérifiée au lancement ; Trame ne bundle pas le CLI. |

---

## 5. Modèle de données

```
Projet (repo git)
 ├─ path, remote, branche par défaut
 └─ Sessions [1..n]
     ├─ type : repo | worktree(branche)
     ├─ état : idle | working | waiting_approval | waiting_input | done | error | stopped
     ├─ preset de permissions : prudent | standard | autonome
     ├─ profil(s) MCP attachés + MCPs individuels
     ├─ participation au mesh : rôle, port, connexions
     ├─ agent : claude-code (seule valeur en V1, extensible)
     ├─ compte Anthropic assigné
     ├─ session Claude Code (id, transcript, resume)
     └─ métriques : tokens in/out, coût estimé, durée, dernier événement

Compte Anthropic
 ├─ nom d'affichage, email, couleur/avatar
 ├─ CLAUDE_CONFIG_DIR dédié (~/.trame/accounts/<nom>)
 ├─ type : abonnement (Pro/Max) | API
 └─ état : connecté | déconnecté | expiré

MCP (bibliothèque centrale)
 ├─ nom, commande/URL, transport (stdio | http | sse)
 ├─ variables d'env (valeurs sensibles → référence Keychain)
 └─ état runtime : running | stopped | error, logs

Profil MCP
 └─ liste ordonnée de MCPs

Mesh
 ├─ secret (Keychain), plage de ports
 ├─ connexions locales : paires (session ↔ session)
 └─ pairs distants : nom, adresse:port, état de joignabilité
```

---

## 6. Fonctionnalités

### F1 — Projets, sessions et worktrees

- **F1.1** Ajouter un projet par glisser-déposer d'un dossier ou sélection ; détection automatique du repo git, de la branche, du remote, du `CLAUDE.md`.
- **F1.2** Créer une session sur le repo (branche courante) **ou** sur un nouveau worktree : saisie du nom de branche → `git worktree add` dans un emplacement géré par Trame (`~/.trame/worktrees/<projet>/<branche>`), session lancée dedans.
- **F1.3** Lancement d'une session = `claude` (ou `claude --resume <id>`) dans un PTY du démon, avec settings/hooks injectés, `.mcp.json` généré (cf. F3, F4) et environnement du compte assigné (`CLAUDE_CONFIG_DIR`, cf. F9).
- **F1.4** Cycle de vie : démarrer, interrompre (Esc), arrêter, relancer, dupliquer (même config, nouveau worktree), archiver. Suppression d'une session de worktree = proposition de merge ou de suppression de la branche (cf. F6).
- **F1.5** Prompt initial optionnel à la création (« lance la session avec cette mission ») — brique de l'orchestration V2.
- **F1.6** États visibles en permanence dans la sidebar : pastille d'état, durée d'activité, badge d'attente.
- **F1.7** **Restauration** : à l'ouverture, l'app se réattache aux sessions vivantes du démon (scrollback inclus) et propose `--resume` pour celles arrêtées depuis.
- **F1.8** **Nommage** : le nom de session est auto-généré à la création — aucune saisie requise (dérivé du projet et de la branche/worktree, ou compteur : `trame-api-2`) — et renommable à tout moment. Le rôle mesh est un slug unique dérivé du nom, renommable indépendamment (cf. F4.5) pour garder un adressage naturel entre agents (« demande au reviewer de… »).
- **F1.9** **Défauts par projet** : compte, profils MCP et preset de permissions de la dernière session sont mémorisés par projet et pré-appliqués à chaque nouvelle session (modifiables avant lancement). Les templates nommés réutilisables arrivent en V2.

### F2 — Vue session

- **F2.1** Terminal embarqué plein cadre (SwiftTerm), thème cohérent avec la DA, taille de police réglable.
- **F2.2** Barre native au-dessus/à côté du terminal : état, branche, coût de la session, MCPs actifs (avec état de santé), participation au mesh, preset de permissions.
- **F2.3** Actions rapides natives : approuver/refuser la permission en attente, envoyer un prompt sans focus dans le terminal, ouvrir le dossier dans le Finder/l'éditeur, copier le chemin.
- **F2.4** Panneau latéral « Activité » : résumé chronologique lisible (fichiers touchés, commandes lancées, messages mesh) reconstruit depuis le transcript — pour rattraper une session sans relire le terminal.
- **F2.5** V2 (SDK) : la vue conversation devient progressivement native (bulles, diffs inline, todos), le terminal restant disponible en mode « raw ».

### F3 — Bibliothèque MCP et profils

- **F3.1** Bibliothèque centrale : un MCP est défini **une fois** (nom, commande ou URL, transport, env). Formulaire guidé + import depuis un `.mcp.json` existant ou une commande `claude mcp add` collée.
- **F3.2** Secrets : toute valeur marquée sensible est stockée dans le Keychain ; les `.mcp.json` générés référencent des variables d'environnement injectées au lancement — **jamais de clé en clair sur disque**.
- **F3.3** Attachement par session : toggles dans la vue session ; Trame régénère le `.mcp.json` du répertoire de travail et signale qu'un redémarrage de session est requis pour appliquer.
- **F3.4** Profils : ensembles nommés (« Stack Web » = postgres + playwright + context7). Une session peut combiner profils + MCPs individuels. Modifier un profil propose la propagation aux sessions qui l'utilisent.
- **F3.5** Health-check : pour chaque MCP actif d'une session, état (running / error), dernier message d'erreur, accès aux logs stderr. Un MCP en échec remonte dans l'inbox.
- **F3.6** Les MCPs des worktrees héritent par défaut de la config de la session « mère » du projet, surchargeable.

### F4 — Mesh talkie-walkie

- **F4.1** **Auto-provisioning complet** : quand l'utilisateur connecte des sessions, Trame alloue les ports (`INTERCOM_PORT`), génère/réutilise le secret (`INTERCOM_SECRET`, Keychain), déduit `MY_ROLE` du nom de session, écrit `PEERS` dans chaque config, et ajoute le MCP talkie-walkie aux `.mcp.json` concernés. Zéro configuration manuelle.
- **F4.2** **Graphe interactif** : vue dédiée où chaque session est un nœud ; tracer un lien entre deux nœuds = les autoriser à se parler ; supprimer le lien = les isoler. Le graphe reflète l'état réel (nœud grisé si la session est arrêtée).
- **F4.3** **Inspecteur de messages** : flux temps réel des `send_message` / `broadcast_message` (émetteur → destinataire, contenu, horodatage), filtrable par session. Équivalent natif du viewer de la lib.
- **F4.4** **Pairs distants** : ajout manuel d'un pair hors Trame (nom, adresse:port, secret). Le pair apparaît dans le graphe avec un style distinct ; joignabilité testée périodiquement. Documentation claire des prérequis réseau (le port doit être joignable ; VPN/Tailscale recommandé — hors périmètre de Trame).
- **F4.5** Rôles nommés : l'utilisateur peut renommer le rôle d'une session (« reviewer », « testeur ») indépendamment de son nom d'affichage — c'est ce rôle que les autres agents utilisent pour l'adresser.
- **F4.6** Contrainte à documenter : les changements de topologie (`PEERS`) nécessitent un redémarrage des sessions concernées tant que la lib ne supporte pas le rechargement à chaud. → **Évolution souhaitable côté lib** : endpoint de reconfiguration dynamique (issue à ouvrir sur `claude-talkie-walkie`).

### F5 — Attention : inbox, notifications, menu bar

- **F5.1** **Inbox centralisée** : file unique des événements en attente — demandes de permission, questions posées par un agent, fins de tâche, erreurs (session ou MCP), messages mesh signalés. Chaque item : session, horodatage, contexte, actions inline (Approuver / Refuser / Répondre / Voir la session). Traiter l'inbox à vide doit être possible sans jamais changer de vue.
- **F5.2** **Notifications macOS actionnables** : bannière avec boutons Approuver / Refuser / Voir quand l'app est en arrière-plan ; badge du Dock = nombre d'items en attente. Réglage de granularité (tout / bloquants seulement / silencieux) global et par session.
- **F5.3** **Barre de menus** : icône avec état agrégé (● 3 actives · ⚠ 1 en attente) ; le clic ouvre un mini-HUD listant les sessions et les attentes, avec approbation possible directement — sans ouvrir la fenêtre principale.
- **F5.4** Anti-bruit : regroupement des événements rafales, pas de notification pour une session au premier plan.
- **F5.5** **Relais mobile (V1.1)** : envoi opt-in des événements bloquants vers un service de push léger (ntfy ou Pushover, topic/token configuré par l'utilisateur). Contenu minimal — nom de session + type d'événement, jamais le contenu des prompts — pour limiter l'exposition de données à un service tiers.

### F6 — Git : review et actions

- **F6.1** Panneau « Changements » par session : liste des fichiers modifiés + diff colorisé natif, calculé contre la **base de la session** (branche/commit de départ), pas seulement contre HEAD.
- **F6.2** Actions : stage/commit (message pré-rempli proposé), push, **création de PR** (via `gh`, corps pré-rempli depuis le résumé d'activité), et pour un worktree : **merge dans la branche cible + nettoyage du worktree** en un geste.
- **F6.3** Garde-fous : détection des conflits avant merge ; jamais d'action destructive (reset, force-push, suppression de branche non mergée) sans confirmation explicite.
- **F6.4** Indicateurs sidebar : nom de branche, ± lignes, nombre de fichiers modifiés par session.

### F7 — Coûts et usage

- **F7.1** Par session : tokens in/out, coût estimé (grille tarifaire des modèles maintenue dans l'app), durée, modèle utilisé. Source : transcripts JSONL.
- **F7.2** Agrégats : coût du jour / de la semaine, par projet, **par compte** (cf. F9.5) et global ; petit historique visualisé (barres par jour).
- **F7.3** Alertes de seuil : « me prévenir au-delà de X €/jour » → item d'inbox + notification.
- **F7.4** Cas des abonnements (Claude Pro/Max) : afficher les tokens et un « coût équivalent API » clairement libellé comme estimation.

### F8 — Permissions par session

- **F8.1** Trois presets visibles et modifiables à la création puis dans la vue session :
  - **Prudent** : mode par défaut du CLI, tout passe par l'inbox.
  - **Standard** : allowlist d'outils courants (lecture, tests, lint) pré-approuvés via settings générés ; le reste passe par l'inbox.
  - **Autonome** : `--dangerously-skip-permissions`.
- **F8.2** Garde-fou informatif *(décision révisée le 29 juillet 2026 : disponible partout à la demande de l'utilisateur)* : **Autonome est disponible pour toute session**, y compris sur le checkout principal. Le worktree isolé reste la voie recommandée ; hors worktree, l'avertissement est renforcé (l'agent peut tout modifier sans demander). Badge visuel permanent et distinct sur les sessions autonomes.
- **F8.3** L'allowlist du preset Standard est éditable globalement et par projet.

### F9 — Comptes Anthropic (multi-comptes)

- **F9.1** Trame gère plusieurs **comptes Anthropic** (ex. perso / MeilleursBiens). Mécanisme : un répertoire de configuration Claude Code dédié par compte (`CLAUDE_CONFIG_DIR=~/.trame/accounts/<nom>`), injecté dans l'environnement de chaque session lancée. Les logins, settings et transcripts de chaque compte sont ainsi totalement isolés.
- **F9.2** Ajout d'un compte : Trame ouvre un flux de connexion `claude` dans un terminal dédié pointant sur le nouveau `CLAUDE_CONFIG_DIR` (login abonnement ou clé API). État de connexion vérifié et affiché ; alerte inbox si un compte expire.
- **F9.3** Assignation : le compte se choisit **à la création de la session** (avec un compte par défaut global, surchargeable par projet — ex. « tout ce qui est dans `~/work/mb` tourne sur le compte MeilleursBiens »). Changer le compte d'une session existante nécessite un redémarrage de session ; l'historique `--resume` reste attaché au compte d'origine.
- **F9.4** Visibilité : pastille/couleur du compte sur chaque session (sidebar et vue session) pour éviter le classique « j'ai brûlé le quota du mauvais compte ».
- **F9.5** Coûts par compte : toutes les métriques de F7 sont ventilées par compte en plus de par session/projet ; les alertes de seuil sont définissables par compte (utile pour séparer budget perso et budget société).
- **F9.6** Garde-fou : impossible de supprimer un compte auquel des sessions actives sont attachées ; la suppression propose l'archivage des transcripts associés.

### F10 — Design et expérience

- **F10.1** DA **native macOS assumée** : sidebar translucide (vibrancy), matériaux système, SF Symbols, respect des HIG, mode clair et sombre, animations discrètes. Référencer Things et Craft comme étalons de finition.
- **F10.2** Densité maîtrisée : l'écran par défaut est calme ; la densité (métriques, logs) est à un clic, jamais imposée.
- **F10.3** **Navigation clavier complète** : palette de commandes ⌘K (créer une session, sauter à une session, approuver, chercher un MCP…), ⌘1…9 pour les sessions, raccourcis inbox (A approuver, R refuser).
- **F10.4** Layout principal : sidebar (projets → sessions, inbox, mesh, bibliothèque MCP) + zone de contenu. Fenêtres secondaires détachables pour une session (multi-écrans).
- **F10.5** Onboarding premier lancement : détection du CLI Claude Code (version mini), configuration du premier compte Anthropic, proposition d'ajouter un premier projet, installation du démon expliquée.

---

## 7. Exigences non fonctionnelles

| Domaine | Exigence |
|---|---|
| Performance | 10 sessions simultanées sans dégradation UI ; rendu terminal fluide ; réattachement < 1 s. |
| Fiabilité | Crash de l'UI sans impact sur les sessions (démon) ; crash d'une session sans impact sur les autres ; écriture atomique des configs générées. |
| Sécurité | Aucun secret en clair sur disque ; secret mesh généré aléatoirement ; bind des ports mesh sur toutes interfaces uniquement si pairs distants activés, sinon localhost. |
| Vie privée | Aucune télémétrie ; appels réseau limités au mesh, à la vérification de mise à jour Sparkle et au relais push opt-in (F5.5). |
| Compatibilité | macOS 14+, Apple Silicon prioritaire ; dépendance : Claude Code CLI ≥ version à fixer. |
| Respect de l'existant | Trame ne modifie jamais un `.mcp.json` ou settings qu'il n'a pas généré sans diff de confirmation ; ses écritures sont marquées et réversibles. |
| Open source | Repo public sous licence **MIT**, README avec captures, guide de contribution, CI de build. |

---

## 8. Découpage et jalons

### V0 — Squelette (fondations techniques)
Démon `trame-core` + XPC, PTY SwiftTerm, ajout de projet, lancement/arrêt d'une session sur repo, restauration après fermeture. *Critère : une session survit à un quit/relaunch de l'app.*

### V1.0 — Cockpit
- Worktrees en un clic (F1), vue session complète (F2)
- Bibliothèque MCP + profils + Keychain (F3.1–F3.4)
- Inbox + notifications + menu bar (F5)
- Presets de permissions + YOLO encadré (F8)
- Review git native + actions (F6)
- Multi-comptes Anthropic (F9)
- Nommage auto + défauts par projet (F1.8, F1.9)
- Design ⌘K + navigation clavier (F10)

### V1.1 — Mesh
- Auto-provisioning talkie-walkie (F4.1), graphe interactif (F4.2), inspecteur (F4.3)
- Pairs distants (F4.4), health-check MCP (F3.5)
- Coûts et agrégats (F7)
- Relais push mobile opt-in (F5.5)

### V2 — Orchestration active
- Rôles prédéfinis et templates nommés réutilisables — sessions (dev / reviewer / testeur) et projets (« Projet MeilleursBiens » : profil MCP + preset + compte + CLAUDE.md type)
- File de tâches : dispatcher un objectif vers une ou plusieurs sessions
- Session « chef » pilotant les autres via le mesh
- Pipelines simples (implémentation → review → tests) avec conditions
- Migration progressive vers l'Agent SDK : conversation, diffs et approbations rendus nativement

### V3 — Multi-agents
- Deuxième adaptateur d'agent (Codex CLI pressenti) — sert de test de validité de l'interface `AgentAdapter` (§4.4)
- Sessions hétérogènes dans un même projet et **mesh mixte** (ex. Claude Code implémente, Codex review) via talkie-walkie
- Comptes généralisés par fournisseur (Anthropic, OpenAI, …), coûts ventilés par fournisseur/compte
- Adaptateurs suivants selon la demande de la communauté (projet open source)

---

## 9. Risques et points de vigilance

| Risque | Impact | Mitigation |
|---|---|---|
| Évolution du CLI Claude Code (flags, hooks, format JSONL) | Rupture de l'observation d'état | Version mini vérifiée ; couche d'abstraction unique sur le CLI ; tests d'intégration contre chaque release. |
| Démon + PTY persistants : complexité réelle | Retard V0 | C'est le premier chantier ; prototype de validation avant toute UI. |
| Topologie mesh non rechargeable à chaud | UX dégradée (redémarrages) | Issue/PR sur talkie-walkie pour un rechargement dynamique des `PEERS`. |
| Pairs distants : réseau, NAT, sécurité du secret partagé | Surface d'attaque | Localhost par défaut ; documentation VPN/Tailscale ; avertissement explicite à l'activation. |
| Estimation des coûts inexacte (abonnements, cache) | Perte de confiance | Libeller « estimation », détailler la méthode de calcul, tokens bruts toujours visibles. |
| Multi-comptes : `CLAUDE_CONFIG_DIR` reste un mécanisme peu documenté du CLI | Rupture des logins isolés | Tests d'intégration dédiés par release du CLI ; vérification d'état de connexion par compte au lancement ; fallback documenté (un seul compte). |
| Sur-abstraction de `AgentAdapter` conçue sur un seul agent | Complexité inutile ou interface fausse | Interface dimensionnée sur les besoins V1 uniquement ; stabilisée seulement à l'implémentation du 2ᵉ adaptateur (V3) ; les fonctionnalités restent pilotées par capacités déclarées. |
| YOLO même en worktree (accès réseau, credentials globaux) | Incident | Le badge Autonome rappelle le périmètre réel ; documentation honnête des limites de l'isolation worktree. |

---

## 10. Points tranchés (complément de cadrage — 29 juillet 2026)

Tous les points ouverts de la version 1.0 ont été arbitrés :

| Point | Décision |
|---|---|
| Nom des sessions | **Auto-généré** à la création (zéro friction), renommable ensuite ; le rôle mesh est un slug dérivé, renommable indépendamment pour garder un adressage naturel entre agents (F1.8, F4.5). |
| Templates de projet | **Défauts par projet dès la V1** (compte, profils MCP, preset ré-appliqués automatiquement, F1.9) ; templates nommés réutilisables en V2. |
| Licence | **MIT**. |
| Push mobile | **Relais opt-in via ntfy/Pushover en V1.1** (F5.5), contenu minimal. L'app compagnon iOS reste une vision long terme non planifiée. |
| Deuxième adaptateur | **Codex CLI**, cible pressentie confirmée ; réévaluation de l'état de son écosystème (support MCP, hooks, mode non interactif) au démarrage de la V3. |
