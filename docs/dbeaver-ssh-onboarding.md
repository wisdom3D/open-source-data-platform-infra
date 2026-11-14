# Guide d'Onboarding : Accès Sécurisé à PostgreSQL via Tunnel SSH et DBeaver

Ce guide décrit la procédure pas-à-pas pour connecter un client SQL graphique (**DBeaver**, TablePlus, DataGrip, etc.) aux bases de données analytiques de la plateforme (`analytics_prod`, `analytics_staging`).

> [!NOTE]
> **Pourquoi un tunnel SSH ?**
> Pour garantir un niveau de sécurité optimal, le conteneur PostgreSQL **n'est pas exposé sur l'Internet public**. Il écoute exclusivement sur l'interface locale `127.0.0.1` du VPS sur le port configuré par `POSTGRES_HOST_PORT` (**port par défaut : `5433`**, afin d'éviter toute collision avec une éventuelle instance PostgreSQL locale sur le port standard `5432`).
>
> Le tunnel SSH permet de chiffrer l'ensemble des échanges et d'accéder à la base comme si elle tournait en local sur votre poste.

---

## 🧭 Résumé du Flux de Connexion

```
[ Poste de Travail de l'Utilisateur ]
  │
  ├── 1. Client DBeaver (Hôte: localhost, Port: 5433)
  │      │
  │      └── Tunnel SSH Chiffré (Clé Ed25519)
  │             │
                ▼
[ Serveur VPS (<VOTRE_IP_VPS>) ]
  │
  ├── 2. Démon SSH (Port 22) - Groupe 'db_tunnelers' (Sans shell /bin/false)
  │      │
  │      └── Redirection locale stricte (PermitOpen 127.0.0.1:5433)
  │             │
                ▼
  └── 3. Conteneur PostgreSQL (127.0.0.1:5433 -> Conteneur:5432)
         ├── Base de données : analytics_prod
         └── Base de données : analytics_staging
```

---

## 👤 Étape 1 : Génération de la Paire de Clés SSH (Côté Utilisateur)

Chaque utilisateur doit disposer d'une paire de clés cryptographiques SSH dédiée. Nous recommandons l'algorithme moderne et performant **Ed25519**.

### 1.1 Générer la clé dans un terminal

Ouvrez un terminal (**macOS / Linux** ou **Windows PowerShell**) et exécutez la commande suivante :

```bash
ssh-keygen -t ed25519 -C "prenom.nom@organisation.com" -f ~/.ssh/id_ed25519_dataplatform
```

> [!IMPORTANT]
> **Ne pas écraser vos clés existantes :**
> L'option `-f ~/.ssh/id_ed25519_dataplatform` isole cette clé dans un fichier spécifique et garantit que votre clé SSH par défaut (`~/.ssh/id_ed25519` ou `~/.ssh/id_rsa`) ne sera pas écrasée.
>
> Lorsqu'une *passphrase* (mot de passe de protection) vous est demandée, il est fortement recommandé d'en définir une pour protéger votre clé sur votre ordinateur.

### 1.2 Comprendre la paire de clés générée

La commande génère deux fichiers dans votre dossier `~/.ssh/` :
- `id_ed25519_dataplatform` : **Clé privée**. Elle ne doit **JAMAIS** être partagée, envoyée par e-mail ou commitée sur Git. Elle reste confidentielle sur votre poste.
- `id_ed25519_dataplatform.pub` : **Clé publique**. C'est ce fichier (et **uniquement** celui-ci) que vous devez transmettre à votre administrateur de plateforme.

### 1.3 Afficher et copier la clé publique

Affichez le contenu de votre clé publique pour la copier :

#### Sous Linux / macOS :
```bash
cat ~/.ssh/id_ed25519_dataplatform.pub
```
*(Astuce macOS pour copier directement dans le presse-papier : `pbcopy < ~/.ssh/id_ed25519_dataplatform.pub`)*

#### Sous Windows PowerShell :
```powershell
Get-Content $HOME\.ssh\id_ed25519_dataplatform.pub
```
*(Astuce PowerShell pour copier directement : `Get-Content $HOME\.ssh\id_ed25519_dataplatform.pub | Set-Clipboard`)*

Le contenu copié ressemble à ceci :
```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... prenom.nom@organisation.com
```

Transmettez cette chaîne de caractères à l'administrateur de la plateforme via un canal sécurisé.

---

## 🛡️ Étape 2 : Enregistrement de la Clé sur le VPS (Côté Administrateur)

L'administrateur système associe la clé publique au compte de l'utilisateur sur le serveur VPS.

### 2.1 Prérequis Administrateur : Provisionnement des Comptes SSH & SQL
L'administrateur système prépare à la fois l'accès tunnel SSH et les droits PostgreSQL :

1. **Création du compte système SSH restreint :**
   ```bash
   sudo ./scripts/setup_ssh_users.sh <utilisateur>
   ```
   *Ce script configure le groupe `db_tunnelers`, attribue le shell sécurisé `/bin/false`, et initialise le dossier `~/.ssh` avec les permissions appropriées (`700`).*

2. **Création du compte SQL PostgreSQL avec gouvernance Médaillon & RBAC :**
   ```bash
   # Pour un Data Analyst (accès bronze, silver, gold sur staging/prod + sandbox <user>_dev dans staging)
   ./scripts/create_db_user.sh <utilisateur> role_analyst

   # Pour un Décideur / BI (accès strict en lecture sur bronze, silver, gold de prod)
   ./scripts/create_db_user.sh <utilisateur> role_prod_readonly
   ```
   *Ce script génère un mot de passe aléatoire hautement sécurisé via `openssl rand` (32 caractères hex) et assigne le rôle fonctionnel correspondant.*

### 2.2 Ajouter la clé publique au trousseau autorisé
Sur le serveur VPS, exécutez la commande suivante en tant que root :

```bash
echo "<CLE_PUBLIQUE_SSH_FOURNIE>" | sudo tee -a /home/<utilisateur>/.ssh/authorized_keys
```

Exemple concret :
```bash
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... prenom.nom@organisation.com" | sudo tee -a /home/<utilisateur>/.ssh/authorized_keys
```

Vérifiez les permissions strictes :
```bash
sudo chmod 600 /home/<utilisateur>/.ssh/authorized_keys
sudo chown -R <utilisateur>:db_tunnelers /home/<utilisateur>/.ssh
```

> [!TIP]
> Grâce au bloc `Match Group db_tunnelers` configuré dans `/etc/ssh/sshd_config`, ce compte ne dispose **d'aucun accès shell interactif** (`/bin/false`, `PermitTTY no`). Il est techniquement bridé au seul routage de port vers `127.0.0.1:<PORT_POSTGRES>`.

---

## 💻 Étape 3 : Configuration de la Connexion dans DBeaver (Côté Utilisateur)

DBeaver intègre nativement la gestion des tunnels SSH sans nécessiter l'ouverture d'un terminal en tâche de fond.

### 3.1 Créer une nouvelle connexion
1. Ouvrez DBeaver.
2. Cliquez sur le menu **Base de données (Database)** > **Nouvelle connexion (New Connection)**.
3. Sélectionnez **PostgreSQL** puis cliquez sur **Suivant**.

---

### 3.2 Configurer l'onglet SSH (Le Tunnel)
Basculez sur l'onglet **SSH** (ou *SSH Tunnel*) :

| Paramètre | Valeur à renseigner | Description |
| :--- | :--- | :--- |
| **Utiliser un tunnel SSH** | ☑️ **Coché** | Active le rebond SSH automatique |
| **Hôte / IP (Host)** | `<VOTRE_IP_VPS>` | Adresse IP publique ou domaine du VPS |
| **Port** | `22` | Port SSH du serveur (ou port personnalisé) |
| **Nom d'utilisateur** | `<utilisateur>` | Votre identifiant SSH créé à l'étape 2 |
| **Méthode d'authentification** | **Clé publique (Public Key)** | Authentification cryptographique |
| **Fichier de clé privée** | `~/.ssh/id_ed25519_dataplatform` | Chemin vers votre clé **privée** (sans `.pub`) |
| **Mot de passe / Passphrase** | `[Votre Passphrase]` | Mot de passe de la clé (si défini à l'étape 1) |

> [!NOTE]
> **Chemin de la clé sous Windows :**
> Dans l'explorateur de fichiers DBeaver, naviguez vers :
> `C:\Users\<VotreNomUtilisateur>\.ssh\id_ed25519_dataplatform`

---

### 3.3 Configurer l'onglet Principal (Paramètres PostgreSQL)
Revenez sur l'onglet **Principal (Main)** :

| Paramètre | Valeur à renseigner | Remarques |
| :--- | :--- | :--- |
| **Hôte (Host)** | `localhost` ou `127.0.0.1` | Du point de vue de la sortie du tunnel SSH sur le VPS |
| **Port** | `5433` (ou `<PORT_POSTGRES>`) | Port défini par `POSTGRES_HOST_PORT` dans `.env` (**5433** par défaut) |
| **Base de données** | `analytics_prod` ou `analytics_staging` | Les analystes accèdent aux deux ; les utilisateurs de reporting accèdent à `analytics_prod` |
| **Schémas disponibles** | `bronze`, `silver`, `gold`, `<username>_dev` | Architecture Médaillon (`<username>_dev` disponible dans `analytics_staging`) |
| **Nom d'utilisateur** | `<db_user>` | Identifiant SQL communiqué par l'administrateur (ex: `dbt_runner` ou compte dédié) |
| **Mot de passe** | `••••••••` | Mot de passe SQL associé |

---

### 3.4 Bonnes Pratiques de Sécurité dans DBeaver
1. **Activer le mode Lecture Seule (Read-Only) :**
   - Dans les paramètres de la connexion, accédez à **Général (General)** > **Type de connexion (Connection Type)**.
   - Cochez **Connexion en lecture seule (Read-only connection)** pour interdire tout `DROP`, `DELETE` ou `UPDATE` accidentel lors de vos analyses.
   - Sélectionnez l'environnement **Production** (ceci colore l'en-tête de DBeaver en rouge pour rappeler le contexte de production).
2. **Filtrer les schémas :**
   - Dans l'onglet **Filtres (Filters)** > **Schémas (Schemas)**, n'affichez que les schémas utiles (`bronze`, `silver`, `gold`, `<username>_dev`) pour accélérer le chargement des tables et ne pas saturer l'arborescence.

---

### 3.5 Tester et Enregistrer
1. Cliquez sur le bouton **Tester la connexion (Test Connection)** en bas à gauche.
2. DBeaver va d'abord négocier le tunnel SSH, puis établir la liaison avec PostgreSQL.
3. Si le message de succès s'affiche (`Connecté / Connected`), cliquez sur **Terminer (Finish)**.

---

## ⚡ Alternative : Ouverture du Tunnel en Ligne de Commande

Si vous préférez utiliser un autre outil SQL (TablePlus, DataGrip, VS Code SQLTools, psql local), vous pouvez maintenir le tunnel ouvert dans un terminal :

```bash
ssh -N -L 5433:127.0.0.1:5433 <utilisateur>@<VOTRE_IP_VPS> -i ~/.ssh/id_ed25519_dataplatform
```

*Explications des options :*
- `-N` : N'exécute aucune commande shell distante (requis par `/bin/false`).
- `-L 5433:127.0.0.1:5433` : Redirige le port local `5433` vers le port `5433` sur la boucle locale du VPS.
- `-i` : Spécifie la clé privée dédiée.

Vous pouvez ensuite configurer n'importe quel client local sur `Host: 127.0.0.1`, `Port: 5433`.

---

## ❓ Dépannage et Erreurs Fréquentes

| Symptôme / Erreur | Cause probable | Solution |
| :--- | :--- | :--- |
| **`Permission denied (publickey)`** | La clé publique n'est pas dans `authorized_keys` ou la mauvaise clé privée a été sélectionnée dans DBeaver. | Vérifiez que vous pointez bien vers `id_ed25519_dataplatform` (et non la clé publique `.pub`). Demandez à l'administrateur de confirmer la présence de la clé sur le VPS. |
| **`Channel open failed: administratively prohibited`** | Le port cible demandé dans le tunnel n'est pas autorisé par `PermitOpen` dans `/etc/ssh/sshd_config`. | Vérifiez que le port configuré dans DBeaver est bien `5433` (ou la valeur de `POSTGRES_HOST_PORT` du `.env`). |
| **`Connection refused` sur le port 5433** | Le conteneur PostgreSQL n'est pas démarré ou n'écoute pas sur le port `5433`. | L'administrateur doit vérifier sur le VPS l'état du conteneur via `docker compose ps` et les logs via `docker compose logs postgres`. |
| **`This service allows only port forwarding`** | Comportement normal lors d'une tentative de connexion SSH en mode terminal interactif (`ssh user@vps`). | L'utilisateur n'a pas de shell interactif par conception de sécurité (`/bin/false`). Le tunnel doit être utilisé via DBeaver ou avec l'option `-N`. |

