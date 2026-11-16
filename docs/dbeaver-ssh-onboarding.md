# Guide d'Onboarding : Accès Sécurisé à PostgreSQL via Tunnel SSH et DBeaver

Ce guide fournit la procédure pas-à-pas pour connecter un client SQL graphique (**DBeaver**, TablePlus, DataGrip, etc.) aux bases de données analytiques de la plateforme (`analytics_staging` et `analytics_prod`).

> [!NOTE]
> **Architecture de Sécurité en Bref :**
> - Le conteneur PostgreSQL **n'est pas exposé sur l'Internet public**. Il écoute exclusivement sur l'adresse de bouclage locale `127.0.0.1` du VPS sur le port configuré par `POSTGRES_HOST_PORT` (**port par défaut : `5433`**).
> - Les analystes et utilisateurs métiers se connectent via un **tunnel SSH chiffré**, avec un compte système sans shell interactif (`/bin/false`) appartenant au groupe sécurisé `db_tunnelers`.
> - Chaque analyste dispose d'un bac à sable dédié **`<username>_dev`** dans la base `analytics_staging`.

---

```
[ Poste de Travail de l'Utilisateur ]
  │
  ├── Client DBeaver (Hôte SQL : 127.0.0.1, Port : 5433)
  │      │
  │      └── Tunnel SSH Chiffré (Clé Ed25519)
  │             │
                ▼
[ Serveur VPS (<VOTRE_IP_VPS>) ]
  │
  ├── Démon SSH (Port 22) - Groupe 'db_tunnelers' (Shell /bin/false)
  │      │
  │      └── Redirection locale stricte (PermitOpen 127.0.0.1:5433)
  │             │
                ▼
  └── Conteneur PostgreSQL (127.0.0.1:5433 -> Conteneur:5432)
         ├── analytics_staging  (Bronze, Silver, Gold + Sandbox <username>_dev)
         └── analytics_prod     (Bronze, Silver, Gold en lecture seule)
```

---

# 👤 PARTIE A : Étapes pour l'Analyste / Utilisateur

---

## Étape A.1 : Génération de la Paire de Clés SSH (Ed25519)

Chaque collaborateur doit disposer d'une paire de clés SSH dédiée. L'algorithme recommandé est **Ed25519** (rapide, moderne et ultra-sécurisé).

### 🖥️ Option 1 : Sous Windows (PowerShell)

> [!IMPORTANT]
> **Création préalable du dossier `.ssh` obligatoire sous Windows :**
> Sur un système Windows vierge, le dossier `$HOME\.ssh` n'existe pas par défaut. Tenter de lancer `ssh-keygen` sans l'avoir créé au préalable provoquera l'erreur :
> `Saving key "...": No such file or directory`.

Ouvrez **PowerShell** et exécutez :

```powershell
# 1. Créer le dossier .ssh s'il n'existe pas
mkdir -Force $HOME\.ssh

# 2. Générer la clé dédiée à la plateforme
ssh-keygen -t ed25519 -C "prenom.nom@entreprise.com" -f $HOME\.ssh\id_ed25519_dataplatform
```

Lors de la commande, appuyez sur **Entrée** pour valider ou saisissez une *passphrase* (fortement recommandé).

---

### 🐧 Option 2 : Sous Linux ou macOS (Terminal)

Ouvrez votre terminal. Sous macOS et Linux, le dossier `~/.ssh` est géré nativement :

```bash
ssh-keygen -t ed25519 -C "prenom.nom@entreprise.com" -f ~/.ssh/id_ed25519_dataplatform
```

---

### 🪟 Option 3 : Sous WSL (Ubuntu sur Windows)

Si vous travaillez dans WSL mais utilisez l'application **DBeaver installée sous Windows**, DBeaver doit pouvoir accéder physiquement à votre clé privée depuis le système de fichiers Windows.

Générez la clé dans WSL, puis copiez-la dans votre profil Windows :

```bash
# 1. Générer la clé dans WSL
ssh-keygen -t ed25519 -C "prenom.nom@entreprise.com" -f ~/.ssh/id_ed25519_dataplatform

# 2. Copier les clés vers votre dossier utilisateur Windows
# (Remplacez <UtilisateurWindows> par votre nom de session Windows)
mkdir -p /mnt/c/Users/<UtilisateurWindows>/.ssh
cp ~/.ssh/id_ed25519_dataplatform* /mnt/c/Users/<UtilisateurWindows>/.ssh/
```

---

## Étape A.2 : Transmission de la Clé Publique à l'Administrateur

Deux fichiers ont été générés :
- `id_ed25519_dataplatform` : **Clé privée**. ⚠️ **Ne JAMAIS la partager ni l'envoyer par e-mail ou Slack.** Elle doit rester confidentielle sur votre poste.
- `id_ed25519_dataplatform.pub` : **Clé publique**. C'est ce fichier (et **uniquement celui-ci**) que vous devez transmettre à l'administrateur du VPS.

Affichez et copiez le contenu de votre clé publique :

#### Sous Windows (PowerShell) :
```powershell
Get-Content $HOME\.ssh\id_ed25519_dataplatform.pub | Set-Clipboard
```
*(Le contenu est directement copié dans votre presse-papier).*

#### Sous macOS :
```bash
pbcopy < ~/.ssh/id_ed25519_dataplatform.pub
```

#### Sous Linux :
```bash
cat ~/.ssh/id_ed25519_dataplatform.pub
```

Le texte copié commence par `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...`. Transmettez-le à l'administrateur de la plateforme.

---

## Étape A.3 : Configuration de la Connexion dans DBeaver

Une fois que l'administrateur vous a confirmé la création de vos accès, ouvrez **DBeaver** :

1. Cliquez sur le menu **Base de données** > **Nouvelle connexion**.
2. Sélectionnez **PostgreSQL** puis cliquez sur **Suivant**.

---

### 1. Configuration de l'onglet SSH (Le Tunnel)

Basculez sur l'onglet **SSH** (ou *SSH Tunnel*) :

| Champ | Valeur à renseigner | Description |
| :--- | :--- | :--- |
| **Utiliser un tunnel SSH** | ☑️ **Coché** | Active le rebond SSH automatique |
| **Hôte / IP (Host)** | `<VOTRE_IP_VPS>` | Adresse IP publique ou domaine du serveur VPS |
| **Port** | `22` | Port SSH du serveur |
| **Nom d'utilisateur** | `<username>` | Votre identifiant système SSH (ex: `alice`, `bob`) |
| **Méthode d'authentification** | **Clé publique (Public Key)** | Authentification cryptographique |
| **Fichier de clé privée** | `id_ed25519_dataplatform` *(sans .pub)* | Sélectionner le fichier de clé privée sur votre poste |
| **Passphrase** | `••••••••` | Votre mot de passe de clé (si défini à l'étape A.1) |

> [!NOTE]
> **Chemin du fichier de clé sous Windows :**
> `C:\Users\<UtilisateurWindows>\.ssh\id_ed25519_dataplatform`

---

### 2. Configuration de l'onglet Principal (Paramètres PostgreSQL)

Revenez sur l'onglet **Principal (Main)** :

| Champ | Valeur à renseigner | Remarques impératives |
| :--- | :--- | :--- |
| **Hôte (Host)** | **`127.0.0.1`** | ⚠️ **NE JAMAIS ÉCRIRE `localhost`** (voir avertissement ci-dessous) |
| **Port** | `5433` | Port PostgreSQL mappé sur la boucle locale du VPS |
| **Base de données** | `analytics_staging` ou `analytics_prod` | `analytics_staging` pour travailler dans votre sandbox ; `analytics_prod` pour la lecture |
| **Nom d'utilisateur** | `<username>` | Votre identifiant SQL communiqué par l'administrateur |
| **Mot de passe** | `••••••••` | Votre mot de passe SQL communiqué par l'administrateur |

> [!CAUTION]
> **POURQUOI `127.0.0.1` ET NON `localhost` ?**
> Sur Windows, macOS et les distributions Linux modernes, le nom d'hôte `localhost` est résolu en priorité vers l'adresse IPv6 de bouclage `::1`.
> Or, la politique de sécurité SSH sur le VPS n'autorise le tunnelage que sur l'adresse IPv4 : `PermitOpen 127.0.0.1:5433`.
> Si vous saisissez `localhost`, la connexion échouera immédiatement avec l'erreur :
> `Error establishing SSHJ tunnel: Channel open failed: administratively prohibited`.
> **Indiquez toujours explicitement : `127.0.0.1`.**

---

### 3. Schémas et Bonnes Pratiques

- **Dans `analytics_staging` :**
  - Vous disposez de la lecture sur `bronze`, `silver`, `gold`.
  - Vous êtes **propriétaire de votre schéma bac à sable `<username>_dev`** (droits complets pour créer des tables, tester des requêtes, prototyper des modèles dbt).
- **Dans `analytics_prod` :**
  - Accès en lecture seule sur `bronze`, `silver`, `gold`.
  - **Recommandation :** Dans l'onglet *Général* > *Type de connexion*, cochez **Connexion en lecture seule (Read-only connection)** et sélectionnez le profil **Production** (bandeau rouge de protection contre les erreurs d'écriture).

Cliquez sur **Tester la connexion**. Dès que le message de succès s'affiche, cliquez sur **Terminer**.

---

# 🛡️ PARTIE B : Étapes pour l'Administrateur du VPS

L'administrateur du serveur configure le compte système SSH et le compte de base de données PostgreSQL.

---

## Étape B.1 : Rendre les Scripts d'Administration Exécutables

Sur le serveur VPS, placez-vous dans le répertoire du projet et assurez-vous que les permissions d'exécution sont positionnées :

```bash
cd /opt/open-source-data-platform-infra
chmod +x scripts/setup_ssh_users.sh scripts/create_db_user.sh
```

*(Cette étape évite les erreurs `Permission denied` ou `command not found`).*

---

## Étape B.2 : Création du Compte Système SSH Restreint

Exécutez le script [scripts/setup_ssh_users.sh](scripts/setup_ssh_users.sh) avec les privilèges `sudo` :

```bash
sudo ./scripts/setup_ssh_users.sh <username>
```

**Ce que fait ce script :**
- Crée le groupe système `db_tunnelers`.
- Crée l'utilisateur avec le shell bloquant `/bin/false` (aucun accès terminal possible).
- Configure `/etc/ssh/sshd_config` avec :
  ```sshconfig
  Match Group db_tunnelers
      AllowTcpForwarding yes
      PermitOpen 127.0.0.1:5433
      X11Forwarding no
      AllowAgentForwarding no
      PermitTTY no
      ForceCommand /bin/false
  ```
- Initialise le dossier `/home/<username>/.ssh` avec les permissions strictes (`700`).

---

## Étape B.3 : Enregistrement de la Clé Publique de l'Utilisateur

Ajoutez la clé publique transmise par l'analyste dans son fichier `authorized_keys` :

```bash
echo "<CLE_PUBLIQUE_SSH_FOURNIE>" | sudo tee -a /home/<username>/.ssh/authorized_keys
sudo chmod 600 /home/<username>/.ssh/authorized_keys
sudo chown -R <username>:db_tunnelers /home/<username>/.ssh
```

---

## Étape B.4 : Création du Compte SQL et Attribution du Rôle RBAC

Exécutez le script [scripts/create_db_user.sh](scripts/create_db_user.sh) :

```bash
# Pour un Data Analyst (lecture bronze/silver/gold + création auto de la sandbox <username>_dev dans staging) :
./scripts/create_db_user.sh <username> role_analyst

# Pour un profil Décideur / Direction (lecture seule sur prod avec timeouts) :
./scripts/create_db_user.sh <username> role_prod_readonly
```

**Ce que réalise automatiquement le script :**
- Génère un mot de passe aléatoire de haute sécurité via `openssl rand -hex 16`.
- Pour `role_analyst` :
  - Accorde les droits de lecture sur `bronze`, `silver`, `gold` dans `analytics_staging` et `analytics_prod`.
  - **Crée automatiquement le schéma `<username>_dev`** dans `analytics_staging` avec l'utilisateur comme propriétaire (`AUTHORIZATION`).
  - Partage la lecture de ce schéma aux autres analystes pour la relecture de code.

---

## Étape B.5 : Transmission Sécurisée de la Fiche de Connexion

Transmettez à l'utilisateur ses paramètres de connexion via un canal sécurisé :

```text
============================================================
Fiche de Connexion Base de Données - Plateforme Data
============================================================
Paramètres du Tunnel SSH :
  - Hôte SSH           : <VOTRE_IP_VPS>
  - Port SSH           : 22
  - Utilisateur SSH    : <username>
  - Authentification   : Clé publique (id_ed25519_dataplatform)

Paramètres PostgreSQL :
  - Hôte SQL           : 127.0.0.1  (ATTENTION : ne pas mettre localhost !)
  - Port SQL           : 5433
  - Base de données    : analytics_staging (Sandbox / Dev) ou analytics_prod
  - Votre Schéma Dev   : <username>_dev (dans analytics_staging)
  - Utilisateur SQL    : <username>
  - Mot de passe SQL   : <mot_de_passe_généré>

Documentation complète : docs/dbeaver-ssh-onboarding.md
============================================================
```

---

## ❓ FAQ & Résolution des Erreurs Fréquentes

| Erreur dans DBeaver | Cause technique | Solution |
| :--- | :--- | :--- |
| **`Error establishing SSHJ tunnel: Channel open failed: administratively prohibited`** | Le champ Hôte dans l'onglet Main contient `localhost` (résolu en IPv6 `::1`), ou le port n'est pas `5433`. | Remplacez `localhost` par **`127.0.0.1`** dans l'onglet Principal. Vérifiez que le port est bien `5433`. |
| **`Permission denied (publickey)`** | La mauvaise clé privée a été sélectionnée, ou la clé publique n'a pas été ajoutée au VPS. | Sélectionnez le fichier sans `.pub` (`id_ed25519_dataplatform`). L'admin doit vérifier `/home/<username>/.ssh/authorized_keys`. |
| **`Saving key "...": No such file or directory` (Windows)** | Le dossier `.ssh` n'existe pas dans votre répertoire utilisateur Windows. | Exécutez `mkdir -Force $HOME\.ssh` dans PowerShell avant de lancer `ssh-keygen`. |
| **`Connection refused` sur le port 5433** | Le conteneur Docker PostgreSQL n'est pas démarré sur le VPS. | L'admin doit lancer `docker compose up -d postgres` sur le VPS. |
| **`This service allows only port forwarding`** | Tentative de connexion en terminal interactif (`ssh user@vps`). | Comportement normal de sécurité : les comptes tunnelers n'ont pas de shell interactif (`/bin/false`). Utilisez DBeaver ou l'option `ssh -N`. |
