# Open Source Modern Data Platform - Infrastructure

[![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-blue?logo=docker)](https://docs.docker.com/compose/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16--alpine-336791?logo=postgresql)](https://www.postgresql.org/)
[![Apache Airflow](https://img.shields.io/badge/Apache_Airflow-2.9.2-017CEE?logo=apacheairflow)](https://airflow.apache.org/)
[![Apache Superset](https://img.shields.io/badge/Apache_Superset-4.0.1-23C5B1?logo=apachesuperset)](https://superset.apache.org/)
[![dbt-core](https://img.shields.io/badge/dbt-postgres_1.8-FF694B?logo=dbt)](https://www.getdbt.com/)
[![License](https://img.shields.io/badge/License-Apache_2.0-green.svg)](LICENSE)

Ce dépôt est un **template open-source prêt à l'emploi** pour déployer une plateforme de données moderne sur un serveur virtuel privé (**VPS de type 4 vCPU, 8 Go+ RAM** sous Ubuntu 24.04 LTS ou Debian 12).

> [!IMPORTANT]
> **Dépôt Public & Zéro Donnée Codée en Dur :**
> Ce projet est conçu pour être cloné et réutilisé publiquement. Aucun nom de domaine personnel, adresse IP publique, mot de passe en clair ou compte nominatif n'est présent dans les fichiers suivis par Git. L'intégralité du paramétrage s'effectue via le fichier `.env` ou via des scripts utilitaires dédiés.

---

## 📚 Guides & Documentation

- 📖 **[Guide complet d'onboarding Utilisateurs : Génération de clés SSH & Configuration DBeaver](docs/dbeaver-ssh-onboarding.md)** : Procédure pas-à-pas illustrée pour les analystes et administrateurs (génération de clé Ed25519 sous Windows/macOS/Linux, enregistrement sur le VPS, configuration du tunnel natif DBeaver, et bonnes pratiques de lecture seule).

---

## 🏛️ Architecture & Coexistence sur le VPS

Cette infrastructure est conçue pour **cohabiter pacifiquement avec des services déjà actifs sur l'hôte** (notamment une instance PostgreSQL locale sur le port standard `5432` et un serveur Web Nginx gérant déjà d'autres sites) :

```
                                  [ INTERNET PUBLIC ]
                                           │
                        ┌──────────────────┴──────────────────┐
                        ▼                                     ▼
             https://${AIRFLOW_DOMAIN}             https://${SUPERSET_DOMAIN}
                        │                                     │
       ┌────────────────┼─────────────────────────────────────┼────────────────┐
       │ HÔTE VPS       ▼                                     ▼                │
       │     [ Nginx Reverse Proxy Hôte (ports 80 / 443 SSL Certbot) ]         │
       │        ├── proxy_pass ────────────────────────┐                      │
       │        │   (WebSockets + X-Forwarded-Proto)    │                      │
       │        ▼                                       ▼                      │
       │  127.0.0.1:${AIRFLOW_HOST_PORT}         127.0.0.1:${SUPERSET_HOST_PORT} │
       │  (défaut: 8080)                         (défaut: 8088)                │
       │        │                                       │                      │
       │        │         [ Instance Postgres Hôte sur port 5432 (intacte) ]   │
       │        │                                                              │
       │        ▼                                                              │
       │  ┌─────────────────────────────────────────────────────────────┐      │
       │  │ RÉSEAU DOCKER (Conteneurs isolés)                           │      │
       │  │                                                             │      │
       │  │   ├── [ Airflow Webserver ] (LocalExecutor)                 │      │
       │  │   ├── [ Airflow Scheduler ]                                 │      │
       │  │   │        │                                                │      │
       │  │   │        └── Volume: /opt/airflow/dbt_project ◄───┐       │      │
       │  │   │                                                 │       │      │
       │  │   ├── [ Superset Webserver ] (Jinja activé)         │       │      │
       │  │   └── [ PostgreSQL 16 (Multi-bases) ]               │       │      │
       │  │            └── Port 5432 interne                    │       │      │
       │  │                 ├── airflow_backend                 │       │      │
       │  │                 ├── superset                        │       │      │
       │  │                 ├── analytics_staging               │       │      │
       │  │                 └── analytics_prod                  │       │      │
       │  │                      ├── Schémas: raw, staging, marts, sandbox     │
       │  │                      └── Rôles: role_analyst, role_prod_readonly   │
       │  └────────────────────▲────────────────────────────────┼───────┘      │
       │                       │                                │              │
       │  127.0.0.1:${POSTGRES_HOST_PORT} (défaut: 5433)        │              │
       │  ▲                                                     │              │
       └──┼─────────────────────────────────────────────────────┼──────────────┘
          │                                                     │
   [ Tunnel SSH Sécurisé ]                     [ Montage Hôte: /opt/dbt-analytics ]
   Match Group 'db_tunnelers'                  Dépôt Git dbt externe synchronisé
   (Comptes sans shell /bin/false)             par l'équipe des analystes data
```

---

## 🔒 Matrice des Ports & Isolation Réseau

> [!NOTE]
> Aucun conteneur Docker n'expose ses ports sur `0.0.0.0`. Toutes les connexions hôte sont confinées à l'interface de bouclage locale `127.0.0.1`.

| Service | Port Interne Conteneur | Port Hôte VPS (Loopback) | Variable `.env` | Exposition Publique |
| :--- | :--- | :--- | :--- | :--- |
| **PostgreSQL 16** | `5432` | `127.0.0.1:5433` | `POSTGRES_HOST_PORT` | **Non** (Tunnel SSH exclusif sur `127.0.0.1:5433`) |
| **Airflow Web** | `8080` | `127.0.0.1:8080` | `AIRFLOW_HOST_PORT` | **Oui** (Via Nginx HTTPS: `${AIRFLOW_DOMAIN}`) |
| **Superset Web** | `8088` | `127.0.0.1:8088` | `SUPERSET_HOST_PORT` | **Oui** (Via Nginx HTTPS: `${SUPERSET_DOMAIN}`) |

---

## 📁 Arborescence du Dépôt

```text
open-source-data-platform-infra/
├── .github/
│   └── workflows/
│       └── deploy.yml                  # Déploiement automatique sur le VPS via SSH au git push
├── airflow/
│   ├── dags/
│   │   └── dbt_run_dag.py              # DAG Airflow standard (BashOperator) exécutant dbt deps et build
│   ├── Dockerfile                      # Image Airflow custom (apache/airflow:2.9.2-python3.11 + git + dbt)
│   └── requirements.txt                # Dépendances Python (dbt-postgres, psycopg2-binary)
├── docs/
│   └── dbeaver-ssh-onboarding.md       # Guide complet d'onboarding : Clés SSH & Configuration DBeaver
├── init-scripts/
│   └── 01-init-dbs.sh                  # Initialisation PostgreSQL (airflow_backend, analytics_staging, analytics_prod, superset)
├── nginx/
│   └── data-platform.conf.template     # Template Nginx isolé utilisant ${AIRFLOW_DOMAIN} et ${SUPERSET_DOMAIN} (envsubst)
├── scripts/
│   ├── create_db_user.sh               # Script utilitaire de création d'utilisateurs SQL avec mot de passe aléatoire et rôle RBAC
│   ├── setup_env.sh                    # ⚙️ Assistant interactif de configuration .env & génération des secrets
│   └── setup_ssh_users.sh              # Script root générique créant les utilisateurs SSH sans shell ($@) dans 'db_tunnelers'
├── sql/
│   └── 01_roles_and_governance.sql     # Définition des schémas Médaillon (bronze, silver, gold) et rôles RBAC
├── superset/
│   ├── Dockerfile                      # Image Superset custom (apache/superset:4.0.1 + psycopg2-binary)
│   └── superset_config.py              # Configuration globale Superset (ENABLE_TEMPLATE_PROCESSING, ENABLE_PROXY_FIX)
├── .env.example                        # Modèle complet et documenté de toutes les variables d'environnement
├── .gitignore                          # Exclusion stricte (.env, fichiers générés, logs, caches)
├── deploy.sh                           # ⚡ Script d'installation & déploiement "One-Click" automatisé
├── docker-compose.yml                  # Orchestration globale paramétrée via .env
└── README.md                           # Documentation pas à pas de déploiement et d'exploitation
```

---

## 🔐 Gouvernance des Données (Architecture Médaillon & RBAC)

La plateforme implémente une gouvernance basée sur l'**architecture Médaillon** (`bronze`, `silver`, `gold`) et le contrôle d'accès basé sur les rôles ([sql/01_roles_and_governance.sql](sql/01_roles_and_governance.sql)) :

### 1. Organisation des Bases et Schémas Médaillon

Les bases de données `analytics_staging` et `analytics_prod` disposent toutes deux des schémas :
- **`bronze`** : Données brutes ingérées directement depuis les sources ELT.
- **`silver`** : Modèles intermédiaires nettoyés, dédoublonnés, enrichis et conformés via dbt.
- **`gold`** : Modèles métiers dimensionnels finaux, tables de faits et marts de KPIs.

### 2. Matrice des Rôles Fonctionnels

| Rôle | Base `analytics_staging` | Base `analytics_prod` | Garde-fous & Propriétés |
| :--- | :--- | :--- | :--- |
| **`role_analyst`** | • `SELECT` sur `bronze`, `silver`, `gold`<br>• Propriétaire (`ALL`) de son schéma dédié `<username>_dev` | • `SELECT` sur `bronze`, `silver`, `gold` (Audit & Debug) | • Visibilité et lecture croisée des schémas dev entre pairs analystes. |
| **`role_prod_readonly`** | ❌ **Aucun accès** (Connexion refusée) | • `SELECT` sur `bronze`, `silver`, `gold` (Reporting & BI) | • `statement_timeout = '120s'`<br>• `idle_in_transaction_session_timeout = '60s'` |

### 3. Création d'Utilisateurs SQL & Sandbox Développeur (`create_db_user.sh`)

L'administrateur provisionne un utilisateur SQL en une seule commande via [scripts/create_db_user.sh](scripts/create_db_user.sh) :

```bash
# Rendre le script exécutable
chmod +x scripts/create_db_user.sh

# 1. Créer un compte Data Analyst
./scripts/create_db_user.sh <nom_utilisateur> role_analyst

# 2. Créer un compte Décideur / Direction / Superset (lecture seule sur prod)
./scripts/create_db_user.sh <nom_utilisateur> role_prod_readonly
```

**Actions automatiques exécutées :**
- Génère un mot de passe aléatoire de haute entropie (`openssl rand -hex 16`).
- Pour un **`role_analyst`** :
  - Accorde les droits de lecture sur `bronze`, `silver`, `gold` dans `analytics_staging` et `analytics_prod`.
  - Crée automatiquement son schéma bac à sable dédié **`<username>_dev`** dans `analytics_staging` (avec propriété complète).
  - Accorde le droit de lecture sur ce schéma `<username>_dev` aux autres membres de `role_analyst` (collaboration et revue de code).
- Pour un **`role_prod_readonly`** :
  - Restreint l'accès strictement à `analytics_prod` en lecture seule, avec timeouts automatiques anti-blocage (120s max par requête).

---

## 🛠️ Prérequis Système

Sur votre VPS (Ubuntu 24.04 LTS ou Debian 12) :
1. **Docker Engine & Docker Compose v2** installés et actifs (`docker compose version`).
2. **Nginx** déjà installé sur l'hôte (`sudo apt install nginx -y`).
3. **Certbot** avec le plugin Nginx (`sudo apt install certbot python3-certbot-nginx gettext-base -y`).
4. **Enregistrements DNS (Type A)** configurés chez votre registrar :
   - `AIRFLOW_DOMAIN` (ex: `elt.votre-domaine.com`) pointant vers l'IP de votre VPS.
   - `SUPERSET_DOMAIN` (ex: `bi.votre-domaine.com`) pointant vers l'IP de votre VPS.

---

## 🚀 Déploiement de la Plateforme

### Méthode Recommandée : Configuration Assistée & Déploiement en 2 Commandes (⚡)

Pour une mise en production rapide sans manipulation manuelle de clés ou de secrets, utilisez notre **assistant interactif** [scripts/setup_env.sh](scripts/setup_env.sh) couplé au script d'automatisation [deploy.sh](deploy.sh) :

```bash
# 1. Cloner le répertoire d'infrastructure sur le VPS
sudo mkdir -p /opt/open-source-data-platform-infra
sudo chown -R $USER:$USER /opt/open-source-data-platform-infra
git clone https://github.com/<votre-organisation>/open-source-data-platform-infra.git /opt/open-source-data-platform-infra
cd /opt/open-source-data-platform-infra

# 2. Cloner le dépôt dbt analytique externe dans son répertoire dédié
sudo mkdir -p /opt/dbt-analytics
sudo chown -R $USER:$USER /opt/dbt-analytics
git clone <URL_DU_DEPOT_DBT> /opt/dbt-analytics

# 3. ÉTAPE 1/2 : Assistant interactif (saisie des domaines & génération automatique des secrets)
chmod +x scripts/setup_env.sh
./scripts/setup_env.sh

# 4. ÉTAPE 2/2 : Lancer le déploiement One-Click
chmod +x deploy.sh
sudo ./deploy.sh

# 5. Activer le certificat HTTPS Let's Encrypt (recommandé après déploiement)
sudo certbot --nginx -d "${AIRFLOW_DOMAIN}" -d "${SUPERSET_DOMAIN}"
```

#### Ce que prend en charge l'assistant [scripts/setup_env.sh](scripts/setup_env.sh) :
- Demande interactivement vos domaines FQDN (`AIRFLOW_DOMAIN`, `SUPERSET_DOMAIN`), le port loopback PostgreSQL (défaut `5433`) et le chemin dbt.
- Génère automatiquement des clés cryptographiques et des mots de passe robustes (OpenSSL 128-bit) pour PostgreSQL, Airflow et Superset.
- Crée le fichier `.env` avec les permissions strictes `chmod 600 .env` et affiche un récapitulatif clair de tous les identifiants générés.

#### Ce que réalise ensuite automatiquement [deploy.sh](deploy.sh) :
1. **Permissions dbt :** Prépare le dossier `${DBT_PROJECT_HOST_PATH}` et configure l'ownership `50000:0` (UID Airflow).
2. **Build & Start :** Compile les images Docker custom et démarre tous les conteneurs avec `docker compose up -d --build`.
3. **Attente active :** Sonde le conteneur PostgreSQL via `pg_isready` jusqu'à ce qu'il soit pleinement opérationnel.
4. **Gouvernance Médaillon & RBAC :** Applique automatiquement [sql/01_roles_and_governance.sql](sql/01_roles_and_governance.sql) sur `analytics_staging` et `analytics_prod`.
5. **Initialisation Superset :** Exécute les migrations de métadonnées, crée le compte administrateur et charge les rôles/permissions.
6. **Vhost Nginx isolé :** Génère `/etc/nginx/sites-available/open-source-data-platform.conf` via `envsubst`, l'active dans `sites-enabled`, valide la syntaxe (`nginx -t`) et recharge Nginx sans interruption de service.
7. **Rapport final :** Affiche un récapitulatif complet des points d'accès et la commande Certbot.

---

### Méthode Alternative : Déploiement Manuel Étape par Étape

Pour auditer ou exécuter manuellement chaque commande :

#### Étape 1 : Cloner le Répertoire d'Infrastructure sur le VPS

```bash
sudo mkdir -p /opt/open-source-data-platform-infra
sudo chown -R $USER:$USER /opt/open-source-data-platform-infra
git clone https://github.com/<votre-organisation>/open-source-data-platform-infra.git /opt/open-source-data-platform-infra
cd /opt/open-source-data-platform-infra
```

---

#### Étape 2 : Préparer le Dépôt dbt Externe

Les modèles dbt sont maintenus dans un dépôt Git distinct par l'équipe Data. Synchronisez-le dans le dossier dédié :

```bash
# Créer le dossier d'accueil hôte
sudo mkdir -p /opt/dbt-analytics
sudo chown -R $USER:$USER /opt/dbt-analytics

# Cloner le dépôt Git dbt
git clone <URL_DU_DEPOT_DBT> /opt/dbt-analytics

# S'assurer que le conteneur Airflow (UID 50000) dispose des droits de lecture/exécution
sudo chmod -R 755 /opt/dbt-analytics
```

---

#### Étape 3 : Configurer le Fichier d'Environnement (`.env`)

Copiez le template `.env.example` :

```bash
cp .env.example .env
```

Générez vos clés secrètes :
```bash
# 1. Clé Fernet Airflow :
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

# 2. Clé Secrète Airflow Webserver :
openssl rand -hex 32

# 3. Clé Secrète Superset :
openssl rand -base64 42
```

Éditez ensuite le fichier `.env` (`nano .env`) pour renseigner :
- Vos sous-domaines réels (`AIRFLOW_DOMAIN` et `SUPERSET_DOMAIN`).
- Vos clés secrètes générées.
- Les mots de passe administrateurs et bases de données.

---

#### Étape 4 : Déployer la Configuration Nginx Isolée & Certbot SSL

Pour intégrer Airflow et Superset au serveur Nginx de l'hôte **sans risquer d'altérer vos vhosts existants** :

```bash
# 1. Charger les variables d'environnement dans le shell courant
set -a && source .env && set +a

# 2. Substituer les variables dans le template sans écraser les variables internes Nginx
envsubst '${AIRFLOW_DOMAIN} ${SUPERSET_DOMAIN} ${AIRFLOW_HOST_PORT} ${SUPERSET_HOST_PORT}' \
  < nginx/data-platform.conf.template \
  | sudo tee /etc/nginx/sites-available/open-source-data-platform.conf

# 3. Activer le site dans sites-enabled
sudo ln -sf /etc/nginx/sites-available/open-source-data-platform.conf /etc/nginx/sites-enabled/

# 4. Vérifier la syntaxe globale Nginx
sudo nginx -t

# 5. Recharger Nginx
sudo systemctl reload nginx

# 6. Activer le certificat HTTPS Let's Encrypt automatique
sudo certbot --nginx -d "${AIRFLOW_DOMAIN}" -d "${SUPERSET_DOMAIN}"
```

---

#### Étape 5 : Configurer les Accès Tunnel SSH Sécurisés

Rendez les scripts d'administration exécutables et lancez le provisionnement des utilisateurs :

```bash
chmod +x scripts/setup_ssh_users.sh scripts/create_db_user.sh

# Créer un ou plusieurs comptes pour l'équipe Data
sudo ./scripts/setup_ssh_users.sh <utilisateur_1> <utilisateur_2>
```

Ce script :
- Crée le groupe système restreint `db_tunnelers`.
- Configure `/etc/ssh/sshd_config` pour autoriser **uniquement** le port forwarding vers `127.0.0.1:${POSTGRES_HOST_PORT:-5433}`.
- Interdit formellement le shell interactif (`/bin/false`) et la pseudo-allocation de terminal (`PermitTTY no`).
- Configure automatiquement les répertoires `~/.ssh` et fichiers `authorized_keys` de chaque compte avec les permissions strictes (`700`/`600`).

> [!TIP]
> **Procédure complète d'onboarding (Génération de clés & DBeaver) :**
> Consultez notre guide dédié pas-à-pas pour vos analystes et utilisateurs :
> 👉 **[Guide complet d'onboarding Utilisateurs : Génération de clés SSH & Configuration DBeaver](docs/dbeaver-ssh-onboarding.md)**

---

#### Étape 6 : Démarrer l'Infrastructure Conteneurisée

Lancez le build des images custom et le démarrage des conteneurs :

```bash
docker compose up -d --build
```

Vérifiez l'état d'exécution et les logs d'initialisation :
```bash
# Vérifier l'état de santé
docker compose ps

# Suivre la migration des bases de données et l'application de la gouvernance
docker compose logs -f airflow-init superset-init postgres
```

Accédez ensuite directement à vos interfaces web sécurisées en HTTPS :
- **Airflow :** `https://${AIRFLOW_DOMAIN}`
- **Superset :** `https://${SUPERSET_DOMAIN}`

---

## 👩‍💻 Connexion Analyste à la Base PostgreSQL via Tunnel SSH

Pour interroger la base de données de production (`analytics_prod`) ou de staging (`analytics_staging`) avec un IDE SQL (DBeaver, TablePlus, DataGrip, VS Code) :

Consultez le **[Guide complet d'onboarding Utilisateurs : Génération de clés SSH & Configuration DBeaver](docs/dbeaver-ssh-onboarding.md)** pour le tutoriel graphique complet.

### Résumé de la commande de tunnel SSH directe
```bash
ssh -N -L 5433:127.0.0.1:5433 <utilisateur>@<VOTRE_IP_VPS> -i ~/.ssh/id_ed25519_dataplatform
```
*(Le flag `-N` empêche l'allocation d'un shell, respectant la restriction de sécurité `/bin/false`).*

Dans votre client SQL local :
- **Hôte :** **`127.0.0.1`** (⚠️ *Ne JAMAIS utiliser `localhost`, car sa résolution en IPv6 `::1` est rejetée par la règle SSH `PermitOpen`*)
- **Port :** `5433` (ou la valeur de `${POSTGRES_HOST_PORT}`)
- **Base :** `analytics_staging` (pour votre sandbox `<username>_dev`) ou `analytics_prod`
- **Utilisateur :** `<identifiant_sql>` (créé via `./scripts/create_db_user.sh`)
- **Mot de passe :** `[votre_mot_de_passe]`

---

## 🔄 Intégration Continue (GitHub Actions)

Le workflow [.github/workflows/deploy.yml](.github/workflows/deploy.yml) synchronise automatiquement l'infrastructure à chaque `git push` sur `main`.

Configurez les secrets dans `GitHub > Settings > Secrets and variables > Actions` :

| Secret | Description | Exemple |
| :--- | :--- | :--- |
| `VPS_HOST` | IP publique ou domaine du serveur | `198.51.100.42` |
| `VPS_USER` | Utilisateur système ayant accès à Docker et sudo | `ubuntu` ou `deployer` |
| `VPS_SSH_KEY` | Clé privée SSH de déploiement | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `VPS_SSH_PORT` | Port SSH du serveur | `22` |
| `VPS_DEPLOY_PATH` | Répertoire d'installation | `/opt/open-source-data-platform-infra` |
| `VPS_DBT_PATH` | Emplacement du code dbt synchronisé | `/opt/dbt-analytics` |

---

## ⚙️ Exploitation & Maintenance Quotidienne

```bash
# Visualiser les métriques de ressources
docker stats

# Consulter les logs du Scheduler Airflow
docker compose logs -f airflow-scheduler

# Redémarrer un conteneur sans perturber la stack
docker compose restart superset

# Sauvegarder la base de production PostgreSQL
docker exec -t data_platform_postgres pg_dump -U postgres -d analytics_prod | gzip > backup_$(date +%F).sql.gz

# Synchroniser manuellement les derniers commits dbt
cd /opt/dbt-analytics && git pull origin main
```
