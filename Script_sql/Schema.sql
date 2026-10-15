-- Database: Risque_Credit_BCC

-- DROP DATABASE IF EXISTS "Risque_Credit_BCC";

CREATE DATABASE "Risque_Credit_BCC"
    WITH
    OWNER = postgres
    ENCODING = 'UTF8'
    LC_COLLATE = 'French_France.utf8'
    LC_CTYPE = 'French_France.utf8'
    LOCALE_PROVIDER = 'libc'
    TABLESPACE = pg_default
    CONNECTION LIMIT = -1
    IS_TEMPLATE = False;


	/* =====================================================================
   PROJET : Pilotage du risque de crédit – BECC (banque fictive, zone CEMAC)
   FICHIER : 01_schema_et_import.sql
   SGBD   : PostgreSQL 14+
   USAGE  : psql -U postgres -d banque_risque -f 01_schema_et_import.sql
            (lancer psql depuis le dossier /data pour que \copy trouve les CSV)
   ===================================================================== */

   -- Nettoyage (ordre inverse des dépendances)
	DROP VIEW  IF EXISTS vw_exposition_enrichie CASCADE;
	DROP TABLE IF EXISTS fait_expositions CASCADE;
	DROP TABLE IF EXISTS dim_clients      CASCADE;
	DROP TABLE IF EXISTS dim_produits     CASCADE;
	DROP TABLE IF EXISTS dim_agences      CASCADE;
	DROP TABLE IF EXISTS dim_date         CASCADE;



	/* ---------------------------------------------------------------------
   1. DIMENSIONS
   --------------------------------------------------------------------- */


   CREATE TABLE dim_date (
    date_complet DATE      PRIMARY KEY,
    annee        SMALLINT  NOT NULL,
    mois         SMALLINT  NOT NULL CHECK (mois BETWEEN 1 AND 12),
    jours        SMALLINT  NOT NULL CHECK (jours BETWEEN 1 AND 31),
    trimestre    SMALLINT  NOT NULL CHECK (trimestre BETWEEN 1 AND 4)
);


  CREATE TABLE dim_agences (
    id_agence       INTEGER       PRIMARY KEY,
    code_agence     VARCHAR(20)   NOT NULL UNIQUE,
    nom_agence      VARCHAR(80)   NOT NULL,
    ville           VARCHAR(60)   NOT NULL,
    region          VARCHAR(60)   NOT NULL,
    pays            VARCHAR(40)   NOT NULL,
    code_pays       CHAR(2)       NOT NULL,
    devise          CHAR(3)       NOT NULL DEFAULT 'XAF',
    type_agence     VARCHAR(30)   NOT NULL,
    date_ouverture  DATE          NOT NULL,
    latitude        NUMERIC(8,4),
    longitude       NUMERIC(8,4)
);


CREATE TABLE dim_produits (
    id_produit         INTEGER       PRIMARY KEY,
    libelle_produit    VARCHAR(80)   NOT NULL,
    categorie_produit  VARCHAR(40)   NOT NULL,
    garantie_type      VARCHAR(80),
    duree_min_mois     SMALLINT      NOT NULL,
    duree_max_mois     SMALLINT      NOT NULL,
    taux_min_pct       NUMERIC(5,2)  NOT NULL,
    taux_max_pct       NUMERIC(5,2)  NOT NULL,
    lgd_reference      NUMERIC(4,2)  NOT NULL CHECK (lgd_reference BETWEEN 0 AND 1)
);


CREATE TABLE dim_clients (
    id_client             INTEGER       PRIMARY KEY,
    nom_client            VARCHAR(120)  NOT NULL,
    type_client           VARCHAR(30)   NOT NULL,
    segment               VARCHAR(20)   NOT NULL,
    secteur_activite      VARCHAR(60)   NOT NULL,
    groupe_economique     VARCHAR(60)   NOT NULL,          -- 'Hors groupe' si indépendant
    id_agence             INTEGER       NOT NULL REFERENCES dim_agences(id_agence),
    note_interne_initiale CHAR(1)       NOT NULL CHECK (note_interne_initiale IN ('A','B','C','D','E')),
    date_entree_relation  DATE          NOT NULL
);


	
	/* ---------------------------------------------------------------------
	   2. TABLE DE FAITS
	   Grain : 1 ligne = 1 crédit x 1 arrêté mensuel (fin de mois)
	   --------------------------------------------------------------------- */



	   CREATE TABLE fait_expositions (
    id_exposition           BIGINT        PRIMARY KEY,
    id_credit               VARCHAR(15)   NOT NULL,          -- dimension dégénérée
    date_arrete             DATE          NOT NULL REFERENCES dim_date(date_complet),
    id_client               INTEGER       NOT NULL REFERENCES dim_clients(id_client),
    id_agence               INTEGER       NOT NULL REFERENCES dim_agences(id_agence),
    id_produit              INTEGER       NOT NULL REFERENCES dim_produits(id_produit),
    date_octroi             DATE          NOT NULL,
    date_echeance           DATE          NOT NULL,
    montant_octroye         BIGINT        NOT NULL CHECK (montant_octroye > 0),
    taux_interet_pct        NUMERIC(5,2)  NOT NULL,
    encours_capital         BIGINT        NOT NULL CHECK (encours_capital >= 0),
    montant_impaye          BIGINT        NOT NULL CHECK (montant_impaye >= 0),
    jours_retard            INTEGER       NOT NULL CHECK (jours_retard >= 0),
    statut_creance          VARCHAR(20)   NOT NULL,
    stage_ifrs9             SMALLINT      NOT NULL CHECK (stage_ifrs9 IN (1,2,3)),
    note_risque             CHAR(1)       NOT NULL CHECK (note_risque IN ('A','B','C','D','E')),
    probabilite_defaut_pct  NUMERIC(6,2)  NOT NULL,
    lgd_pct                 NUMERIC(5,2)  NOT NULL,
    exposition_ead          BIGINT        NOT NULL,
    perte_attendue          BIGINT        NOT NULL,
    provision_constituee    BIGINT        NOT NULL,
    valeur_garantie         BIGINT        NOT NULL,
    garantie_saisie         SMALLINT      NOT NULL CHECK (garantie_saisie IN (0,1)),
    credit_restructure      SMALLINT      NOT NULL CHECK (credit_restructure IN (0,1)),
    montant_recouvre        BIGINT        NOT NULL,
    montant_passe_en_perte  BIGINT        NOT NULL,
    CONSTRAINT uq_credit_arrete UNIQUE (id_credit, date_arrete)
);


	/* ---------------------------------------------------------------------
	   4. INDEX (jointures et filtres Power BI)
	   --------------------------------------------------------------------- */


	    CREATE INDEX ix_fait_date     ON fait_expositions (date_arrete);
		CREATE INDEX ix_fait_client   ON fait_expositions (id_client, date_arrete);
		CREATE INDEX ix_fait_agence   ON fait_expositions (id_agence, date_arrete);
		CREATE INDEX ix_fait_produit  ON fait_expositions (id_produit);
		CREATE INDEX ix_fait_credit   ON fait_expositions (id_credit, date_arrete);
		CREATE INDEX ix_fait_stage    ON fait_expositions (date_arrete, stage_ifrs9);
		CREATE INDEX ix_clients_agence ON dim_clients (id_agence);

		ANALYZE;


		/* ---------------------------------------------------------------------
           5. CONTRÔLES QUALITÉ APRÈS IMPORT (résultats attendus en commentaire)
        --------------------------------------------------------------------- */



		SELECT 'dim_date' AS table_nom, COUNT(*) AS nb_lignes FROM dim_date           
		UNION ALL SELECT 'dim_agences',  COUNT(*) FROM dim_agences                    
		UNION ALL SELECT 'dim_produits', COUNT(*) FROM dim_produits                    
		UNION ALL SELECT 'dim_clients',  COUNT(*) FROM dim_clients                     
		UNION ALL SELECT 'fait_expositions', COUNT(*) FROM fait_expositions;


		-- Orphelins (doit retourner 0 ligne)
		SELECT f.id_exposition FROM fait_expositions f
		LEFT JOIN dim_clients c ON c.id_client = f.id_client WHERE c.id_client IS NULL;

		-- Arrêtés mensuels disponibles (doit retourner 36 fins de mois)
       SELECT COUNT(DISTINCT date_arrete) AS nb_arretes FROM fait_expositions;


	   -- Taux NPL (stage 3) par fin d'année : environ 6.6 % / 16.0 % / 8.4 %
		SELECT date_arrete,
		       ROUND(100.0 * SUM(encours_capital) FILTER (WHERE stage_ifrs9 = 3) / SUM(encours_capital), 1) AS taux_npl_pct
		FROM fait_expositions
		WHERE date_arrete IN ('2023-12-31','2024-12-31','2025-12-31')
		GROUP BY date_arrete ORDER BY date_arrete;







