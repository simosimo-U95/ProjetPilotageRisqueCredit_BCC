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
   FICHIER : 02_vues_power_bi.sql  (à exécuter APRÈS 01_schema_et_import.sql)
   CONTENU : 1 vue de base + 8 vues agrégées (CTE + fonctions de fenêtrage)
   Conventions : NPL = créances en souffrance = stage_ifrs9 = 3 (>= 90 jours de retard)
                 Montants en XAF (FCFA) ; pourcentages exprimés en points (12.5 = 12,5 %)
   ===================================================================== */


   /* ---------------------------------------------------------------------
   V0. Vue de base : fait + dimensions aplaties (sert de source aux autres vues)
   --------------------------------------------------------------------- */
	CREATE OR REPLACE VIEW vw_exposition_enrichie AS
	SELECT
	    f.id_exposition,
	    f.id_credit,
	    f.date_arrete,
	    d.annee,
	    d.trimestre,
	    d.mois,
	    d.annee * 100 + d.mois                           AS annee_mois,
	    d.annee::text || '-T' || d.trimestre::text       AS annee_trimestre,
	    a.id_agence, a.nom_agence, a.ville, a.region, a.pays, a.code_pays,
	    c.id_client, c.nom_client, c.type_client, c.segment, c.secteur_activite, c.groupe_economique,
	    COALESCE(NULLIF(c.groupe_economique, 'Hors groupe'), c.nom_client) AS beneficiaire_risque,
	    p.id_produit, p.libelle_produit, p.categorie_produit,
	    f.date_octroi, f.date_echeance,
	    f.montant_octroye, f.taux_interet_pct,
	    f.encours_capital, f.montant_impaye, f.jours_retard,
	    f.statut_creance, f.stage_ifrs9, f.note_risque,
	    f.probabilite_defaut_pct, f.lgd_pct, f.exposition_ead,
	    f.perte_attendue, f.provision_constituee, f.valeur_garantie,
	    f.garantie_saisie, f.credit_restructure,
	    f.montant_recouvre, f.montant_passe_en_perte,
	    CASE WHEN f.stage_ifrs9 = 3 THEN f.encours_capital ELSE 0 END AS encours_npl,
	    CASE WHEN f.stage_ifrs9 = 2 THEN f.encours_capital ELSE 0 END AS encours_stage2
	FROM fait_expositions f
	JOIN dim_date     d ON d.date_complet = f.date_arrete
	JOIN dim_agences  a ON a.id_agence    = f.id_agence
	JOIN dim_clients  c ON c.id_client    = f.id_client
	JOIN dim_produits p ON p.id_produit   = f.id_produit;



	/* ---------------------------------------------------------------------
   V1. Synthèse mensuelle par pays + TOTAL GROUPE  (Dashboard 1 et 2)
   Techniques : GROUPING SETS, CTE chaînées, LAG, AVG glissante, RANK,
                SUM cumulatif, fenêtre nommée (WINDOW w)
   --------------------------------------------------------------------- */
	CREATE OR REPLACE VIEW vw_synthese_mensuelle AS
	WITH agrege AS (
	    SELECT
	        e.date_arrete, 
	        e.annee, 
	        e.trimestre, 
	        e.mois,
	        CASE 
	            WHEN GROUPING(e.pays) = 1 THEN 'TOTAL GROUPE' 
	            ELSE e.pays 
	        END AS perimetre,
	        COUNT(DISTINCT e.id_credit)                                        AS nb_credits,
	        COUNT(DISTINCT e.id_client)                                        AS nb_clients,
	        SUM(e.encours_capital)                                             AS encours_total,
	        SUM(e.encours_npl)                                                 AS encours_npl,
	        SUM(e.encours_stage2)                                              AS encours_stage2,
	        SUM(e.provision_constituee)                                        AS provisions,
	        SUM(e.provision_constituee) FILTER (WHERE e.stage_ifrs9 = 3)       AS provisions_stage3,
	        SUM(e.perte_attendue)                                              AS perte_attendue,
	        SUM(e.montant_impaye)                                              AS montant_impaye,
	        SUM(e.montant_recouvre)                                            AS recouvrements,
	        SUM(e.montant_passe_en_perte)                                      AS passages_en_perte
	    FROM vw_exposition_enrichie e
	    GROUP BY GROUPING SETS (
	        (e.date_arrete, e.annee, e.trimestre, e.mois, e.pays),
	        (e.date_arrete, e.annee, e.trimestre, e.mois)
	    )
	),
	ratios AS (
	    SELECT a.*,
	        ROUND(100.0 * encours_npl        / NULLIF(encours_total, 0), 2)    AS taux_npl_pct,
	        ROUND(100.0 * encours_stage2     / NULLIF(encours_total, 0), 2)    AS taux_stage2_pct,
	        ROUND(100.0 * provisions_stage3  / NULLIF(encours_npl, 0), 1)      AS taux_couverture_npl_pct,
	        ROUND(100.0 * perte_attendue     / NULLIF(encours_total, 0), 2)    AS taux_perte_attendue_pct
	    FROM agrege a
	),
	calculs_intermediaires AS (
	    SELECT
	        r.*,
	        LAG(r.encours_total) OVER w                                            AS encours_mois_prec,
	        ROUND(100.0 * (r.encours_total - LAG(r.encours_total) OVER w)
	              / NULLIF(LAG(r.encours_total) OVER w, 0), 2)                     AS var_encours_mom_pct,
	              
	        ROUND(r.taux_npl_pct - LAG(r.taux_npl_pct)     OVER w, 2)              AS var_npl_mom_pts,
	        ROUND(r.taux_npl_pct - LAG(r.taux_npl_pct, 12) OVER w, 2)              AS var_npl_yoy_pts,
	        
	        ROUND(AVG(r.taux_npl_pct) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
	                                                                               AS taux_npl_moy_mobile_3m,
	                                                                               
	        r.provisions - COALESCE(LAG(r.provisions) OVER w, r.provisions)        AS dotation_provisions_nette,
	        
	        (r.provisions - COALESCE(LAG(r.provisions) OVER w, r.provisions))
	            + r.passages_en_perte - r.recouvrements                            AS cout_risque_mensuel
	    FROM ratios r
	    WINDOW w AS (PARTITION BY r.perimetre ORDER BY r.date_arrete)
	)
	SELECT
	    ci.*,
	    -- Coût du risque cumulé sur l'année (YTD) appliqué proprement sur le résultat précédent
	    SUM(ci.cout_risque_mensuel) OVER (
	        PARTITION BY ci.perimetre, ci.annee 
	        ORDER BY ci.date_arrete 
	        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
	    )                                                                          AS cout_risque_cumul_annee,
	                  
	    -- Classement des pays par niveau de risque
	    CASE WHEN ci.perimetre <> 'TOTAL GROUPE'
	         THEN RANK() OVER (
	              PARTITION BY ci.date_arrete 
	              ORDER BY ci.taux_npl_pct DESC
	         ) END                                                                 AS rang_pays_risque
	FROM calculs_intermediaires ci;


	/* ---------------------------------------------------------------------
   V2. Synthèse trimestrielle (stock fin de trimestre + flux du trimestre)
   --------------------------------------------------------------------- */
	CREATE OR REPLACE VIEW vw_synthese_trimestrielle AS
	WITH flux AS (
	    SELECT perimetre, annee, trimestre,
	           SUM(cout_risque_mensuel) AS cout_risque_trimestre,
	           SUM(recouvrements)       AS recouvrements_trimestre,
	           SUM(passages_en_perte)   AS pertes_trimestre
	    FROM vw_synthese_mensuelle
	    GROUP BY perimetre, annee, trimestre
	),
	stock AS (
	    SELECT * FROM vw_synthese_mensuelle WHERE mois IN (3, 6, 9, 12)
	)
	SELECT
	    s.perimetre, s.annee, s.trimestre,
	    s.annee::text || '-T' || s.trimestre::text                             AS annee_trimestre,
	    s.date_arrete,
	    s.nb_credits, s.nb_clients, s.encours_total, s.encours_npl, s.provisions,
	    s.taux_npl_pct, s.taux_stage2_pct, s.taux_couverture_npl_pct,
	    f.cout_risque_trimestre, f.recouvrements_trimestre, f.pertes_trimestre,
	    ROUND(s.taux_npl_pct - LAG(s.taux_npl_pct)    OVER w, 2)               AS var_npl_qoq_pts,
	    ROUND(s.taux_npl_pct - LAG(s.taux_npl_pct, 4) OVER w, 2)               AS var_npl_yoy_pts,
	    ROUND(100.0 * (s.encours_total - LAG(s.encours_total) OVER w)
	          / NULLIF(LAG(s.encours_total) OVER w, 0), 2)                     AS var_encours_qoq_pct,
	    ROUND(100.0 * (s.encours_total - LAG(s.encours_total, 4) OVER w)
	          / NULLIF(LAG(s.encours_total, 4) OVER w, 0), 2)                  AS var_encours_yoy_pct
	FROM stock s
	JOIN flux  f ON f.perimetre = s.perimetre AND f.annee = s.annee AND f.trimestre = s.trimestre
	WINDOW w AS (PARTITION BY s.perimetre ORDER BY s.date_arrete);



	/* ---------------------------------------------------------------------
        V3. Synthèse annuelle (arrêté au 31 décembre + flux de l'année)
   --------------------------------------------------------------------- */
		CREATE OR REPLACE VIEW vw_synthese_annuelle AS
		WITH flux AS (
		    SELECT perimetre, annee,
		           SUM(cout_risque_mensuel) AS cout_risque_annee,
		           SUM(recouvrements)       AS recouvrements_annee,
		           SUM(passages_en_perte)   AS pertes_annee
		    FROM vw_synthese_mensuelle
		    GROUP BY perimetre, annee
		)
		SELECT
		    s.perimetre, s.annee, s.date_arrete,
		    s.nb_credits, s.nb_clients, s.encours_total, s.encours_npl, s.provisions,
		    s.taux_npl_pct, s.taux_stage2_pct, s.taux_couverture_npl_pct, s.taux_perte_attendue_pct,
		    f.cout_risque_annee, f.recouvrements_annee, f.pertes_annee,
		    ROUND(100.0 * f.cout_risque_annee / NULLIF(s.encours_total, 0), 2)     AS cout_risque_sur_encours_pct,
		    ROUND(s.taux_npl_pct - LAG(s.taux_npl_pct) OVER w, 2)                  AS var_npl_yoy_pts,
		    ROUND(100.0 * (s.encours_total - LAG(s.encours_total) OVER w)
		          / NULLIF(LAG(s.encours_total) OVER w, 0), 2)                     AS var_encours_yoy_pct
		FROM vw_synthese_mensuelle s
		JOIN flux f ON f.perimetre = s.perimetre AND f.annee = s.annee
		WHERE s.mois = 12
		WINDOW w AS (PARTITION BY s.perimetre ORDER BY s.annee);



		/* ---------------------------------------------------------------------
   V4. Classement des agences (région > ville > agence)  (Dashboard 4)
   Techniques : RANK, DENSE_RANK, NTILE, SUM() OVER partition, Pareto cumulé
   --------------------------------------------------------------------- */
		CREATE OR REPLACE VIEW vw_classement_agences AS
		WITH par_agence AS (
		    SELECT e.date_arrete, e.annee, e.trimestre, e.mois,
		           e.pays, e.region, e.ville, e.id_agence, e.nom_agence,
		           COUNT(DISTINCT e.id_client)  AS nb_clients,
		           SUM(e.encours_capital)       AS encours_total,
		           SUM(e.encours_npl)           AS encours_npl,
		           SUM(e.provision_constituee)  AS provisions,
		           SUM(e.montant_impaye)        AS montant_impaye
		    FROM vw_exposition_enrichie e
		    GROUP BY e.date_arrete, e.annee, e.trimestre, e.mois,
		             e.pays, e.region, e.ville, e.id_agence, e.nom_agence
		),
		ratios AS (
		    SELECT p.*,
		           ROUND(100.0 * encours_npl / NULLIF(encours_total, 0), 2) AS taux_npl_pct
		    FROM par_agence p
		)
		SELECT
		    r.*,
		    RANK()       OVER (PARTITION BY r.date_arrete            ORDER BY r.taux_npl_pct DESC)  AS rang_taux_npl_groupe,
		    RANK()       OVER (PARTITION BY r.date_arrete, r.pays    ORDER BY r.taux_npl_pct DESC)  AS rang_taux_npl_pays,
		    DENSE_RANK() OVER (PARTITION BY r.date_arrete            ORDER BY r.encours_npl DESC)   AS rang_montant_npl,
		    NTILE(4)     OVER (PARTITION BY r.date_arrete            ORDER BY r.taux_npl_pct DESC)  AS quartile_risque,  -- 1 = quartile le plus risqué
		    ROUND(100.0 * r.encours_total
		          / NULLIF(SUM(r.encours_total) OVER (PARTITION BY r.date_arrete, r.pays), 0), 2)   AS part_encours_pays_pct,
		    ROUND(100.0 * SUM(r.encours_npl) OVER (PARTITION BY r.date_arrete
		                                           ORDER BY r.encours_npl DESC, r.id_agence
		                                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
		          / NULLIF(SUM(r.encours_npl) OVER (PARTITION BY r.date_arrete), 0), 2)             AS pareto_npl_cumule_pct,
		    CASE WHEN r.taux_npl_pct >= 20 THEN 'Critique'
		         WHEN r.taux_npl_pct >= 10 THEN 'Élevé'
		         WHEN r.taux_npl_pct >=  5 THEN 'Modéré'
		         ELSE 'Maîtrisé' END                                                                AS niveau_risque
		FROM ratios r;



		/* ---------------------------------------------------------------------
   		V5. Plus gros débiteurs (top 50 par arrêté)  (Dashboard 3)
   		Techniques : ROW_NUMBER, part du portefeuille, Pareto cumulé
   		--------------------------------------------------------------------- */
		CREATE OR REPLACE VIEW vw_top_clients_endettes AS
		WITH par_client AS (
		    SELECT e.date_arrete, e.annee, e.trimestre, e.mois,
		           e.id_client, e.nom_client, e.type_client, e.secteur_activite, e.groupe_economique,
		           e.pays, e.region, e.ville, e.nom_agence,
		           COUNT(DISTINCT e.id_credit)  AS nb_credits,
		           SUM(e.encours_capital)       AS encours_total,
		           SUM(e.encours_npl)           AS encours_npl,
		           SUM(e.montant_impaye)        AS montant_impaye,
		           MAX(e.jours_retard)          AS jours_retard_max,
		           SUM(e.provision_constituee)  AS provisions,
		           SUM(e.valeur_garantie)       AS valeur_garanties
		    FROM vw_exposition_enrichie e
		    GROUP BY e.date_arrete, e.annee, e.trimestre, e.mois,
		             e.id_client, e.nom_client, e.type_client, e.secteur_activite, e.groupe_economique,
		             e.pays, e.region, e.ville, e.nom_agence
		),
		classes AS (
		    SELECT c.*,
		           ROW_NUMBER() OVER (PARTITION BY c.date_arrete ORDER BY c.encours_total DESC, c.id_client) AS rang_encours,
		           ROUND(100.0 * c.encours_total / NULLIF(SUM(c.encours_total) OVER (PARTITION BY c.date_arrete), 0), 2)
		                                                                                                    AS part_portefeuille_pct,
		           ROUND(100.0 * SUM(c.encours_total) OVER (PARTITION BY c.date_arrete
		                                                    ORDER BY c.encours_total DESC, c.id_client
		                                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
		                 / NULLIF(SUM(c.encours_total) OVER (PARTITION BY c.date_arrete), 0), 2)            AS part_cumulee_pct,
		           ROUND(100.0 * c.valeur_garanties / NULLIF(c.encours_total, 0), 1)                         AS couverture_garantie_pct
		    FROM par_client c
		)
		SELECT * FROM classes WHERE rang_encours <= 50;



		/* ---------------------------------------------------------------------
   V6. Grands risques et concentration (bénéficiaire = client ou groupe)
   Paramètres modifiables dans la CTE « parametres » (à valider avec la
   réglementation prudentielle COBAC en vigueur avant tout usage réel).
   --------------------------------------------------------------------- */
		CREATE OR REPLACE VIEW vw_grands_risques AS
		WITH parametres AS (
		    SELECT 30000000000::numeric AS fonds_propres_xaf,   -- fonds propres effectifs de référence
		           10::numeric          AS seuil_grand_risque_pct,
		           25::numeric          AS seuil_alerte_pct,
		           45::numeric          AS plafond_individuel_pct
		),
		benef AS (
		    SELECT e.date_arrete, e.annee, e.trimestre, e.mois,
		           e.beneficiaire_risque,
		           CASE WHEN MAX(e.groupe_economique) = 'Hors groupe'
		                THEN 'Client individuel' ELSE 'Groupe économique' END       AS type_beneficiaire,
		           COUNT(DISTINCT e.id_client)                                       AS nb_clients_lies,
		           STRING_AGG(DISTINCT e.pays, ', ' ORDER BY e.pays)                 AS pays_exposes,
		           SUM(e.encours_capital)                                            AS encours_total,
		           SUM(e.encours_npl)                                                AS encours_npl,
		           SUM(e.provision_constituee)                                       AS provisions
		    FROM vw_exposition_enrichie e
		    GROUP BY e.date_arrete, e.annee, e.trimestre, e.mois, e.beneficiaire_risque
		),
		calc AS (
		    SELECT b.*,
		           p.fonds_propres_xaf,
		           ROUND(100.0 * b.encours_total / p.fonds_propres_xaf, 2) AS ratio_fonds_propres_pct,
		           p.seuil_grand_risque_pct, p.seuil_alerte_pct, p.plafond_individuel_pct
		    FROM benef b CROSS JOIN parametres p
		)
		SELECT
		    c.*,
		    CASE WHEN c.ratio_fonds_propres_pct >= c.plafond_individuel_pct   THEN '3 - Dépassement du plafond'
		         WHEN c.ratio_fonds_propres_pct >= c.seuil_alerte_pct         THEN '2 - Alerte rouge'
		         WHEN c.ratio_fonds_propres_pct >= c.seuil_grand_risque_pct   THEN '1 - Grand risque'
		         ELSE '0 - Normal' END                                                       AS statut_concentration,
		    RANK() OVER (PARTITION BY c.date_arrete ORDER BY c.encours_total DESC)           AS rang_beneficiaire,
		    SUM(CASE WHEN c.ratio_fonds_propres_pct >= c.seuil_grand_risque_pct THEN c.encours_total END)
		        OVER (PARTITION BY c.date_arrete)                                            AS total_grands_risques,
		    ROUND(100.0 * SUM(CASE WHEN c.ratio_fonds_propres_pct >= c.seuil_grand_risque_pct THEN c.encours_total END)
		          OVER (PARTITION BY c.date_arrete) / c.fonds_propres_xaf, 1)                AS total_grands_risques_sur_fp_pct,
		    ROUND(c.ratio_fonds_propres_pct
		          - LAG(c.ratio_fonds_propres_pct) OVER (PARTITION BY c.beneficiaire_risque ORDER BY c.date_arrete), 2)
		                                                                                     AS var_ratio_mom_pts
		FROM calc c;



         /* ---------------------------------------------------------------------
   V7. Migration des créances entre stages (matrice de transition mensuelle)
   Technique : LAG par crédit puis agrégation avec SUM(COUNT(*)) OVER
   --------------------------------------------------------------------- */
           CREATE OR REPLACE VIEW vw_migration_stage AS
			WITH sequence_credit AS (
			    SELECT e.date_arrete, e.annee, e.trimestre, e.mois, e.pays, e.id_credit,
			           e.stage_ifrs9 AS stage_actuel,
			           e.encours_capital,
			           LAG(e.stage_ifrs9) OVER (PARTITION BY e.id_credit ORDER BY e.date_arrete) AS stage_precedent
			    FROM vw_exposition_enrichie e
			)
			SELECT
			    s.date_arrete, s.annee, s.trimestre, s.mois, s.pays,
			    s.stage_precedent, s.stage_actuel,
			    CASE WHEN s.stage_actuel > s.stage_precedent THEN 'Dégradation'
			         WHEN s.stage_actuel < s.stage_precedent THEN 'Amélioration'
			         ELSE 'Stable' END                                                            AS sens_migration,
			    COUNT(*)                                                                          AS nb_credits,
			    SUM(s.encours_capital)                                                            AS encours,
			    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY s.date_arrete, s.pays, s.stage_precedent), 2)
			                                                                                      AS taux_transition_pct
			FROM sequence_credit s
			WHERE s.stage_precedent IS NOT NULL
			GROUP BY s.date_arrete, s.annee, s.trimestre, s.mois, s.pays, s.stage_precedent, s.stage_actuel;



			/* ---------------------------------------------------------------------
  			 V8. Garanties, saisies et recouvrements (Dashboard 3)
   			--------------------------------------------------------------------- */
			CREATE OR REPLACE VIEW vw_garanties_recouvrements AS
			SELECT
			    e.date_arrete, e.annee, e.trimestre, e.mois, e.pays, e.categorie_produit,
			    SUM(e.encours_npl)                                                           AS encours_npl,
			    SUM(e.valeur_garantie) FILTER (WHERE e.stage_ifrs9 = 3)                      AS valeur_garanties_npl,
			    ROUND(100.0 * SUM(e.valeur_garantie) FILTER (WHERE e.stage_ifrs9 = 3)
			          / NULLIF(SUM(e.encours_npl), 0), 1)                                    AS couverture_garantie_npl_pct,
			    COUNT(*) FILTER (WHERE e.garantie_saisie = 1)                                AS nb_garanties_saisies,
			    SUM(e.encours_capital) FILTER (WHERE e.garantie_saisie = 1)                  AS encours_garanties_saisies,
			    SUM(e.montant_recouvre)                                                      AS recouvrements_mois,
			    SUM(e.montant_passe_en_perte)                                                AS pertes_mois,
			    SUM(SUM(e.montant_recouvre)) OVER (PARTITION BY e.pays, e.categorie_produit, e.annee
			                                       ORDER BY e.date_arrete)                   AS recouvrements_cumul_annee,
			    SUM(SUM(e.montant_passe_en_perte)) OVER (PARTITION BY e.pays, e.categorie_produit, e.annee
			                                       ORDER BY e.date_arrete)                   AS pertes_cumul_annee
			FROM vw_exposition_enrichie e
			GROUP BY e.date_arrete, e.annee, e.trimestre, e.mois, e.pays, e.categorie_produit;


			/* ---------------------------------------------------------------------
                 V9. Cohortes d'octroi (vintages) : qualité des crédits selon l'âge
               On ne retient que les crédits octroyés depuis 2023 (historique complet).
            --------------------------------------------------------------------- */
				CREATE OR REPLACE VIEW vw_cohortes_octroi AS
				WITH base AS (
				    SELECT DATE_TRUNC('quarter', e.date_octroi)::date AS trimestre_octroi,
				           ((DATE_PART('year',  e.date_arrete) - DATE_PART('year',  e.date_octroi)) * 12
				            + DATE_PART('month', e.date_arrete) - DATE_PART('month', e.date_octroi))::int AS mois_depuis_octroi,
				           e.id_credit, e.encours_capital, e.encours_npl, e.montant_octroye
				    FROM vw_exposition_enrichie e
				    WHERE e.date_octroi >= DATE '2023-01-01'
				),
				agg AS (
				    SELECT trimestre_octroi, mois_depuis_octroi,
				           COUNT(DISTINCT id_credit) AS nb_credits,
				           SUM(encours_capital)      AS encours,
				           SUM(encours_npl)          AS encours_npl,
				           ROUND(100.0 * SUM(encours_npl) / NULLIF(SUM(encours_capital), 0), 2) AS taux_npl_pct
				    FROM base
				    GROUP BY trimestre_octroi, mois_depuis_octroi
				)
				SELECT
				    a.*,
				    'T' || EXTRACT(QUARTER FROM a.trimestre_octroi)::int || ' ' || EXTRACT(YEAR FROM a.trimestre_octroi)::int AS libelle_cohorte,
				    ROUND(a.taux_npl_pct - LAG(a.taux_npl_pct) OVER (PARTITION BY a.trimestre_octroi ORDER BY a.mois_depuis_octroi), 2)
				                                                                                             AS var_npl_vs_mois_prec_pts,
				    MAX(a.taux_npl_pct) OVER (PARTITION BY a.trimestre_octroi)                               AS pic_npl_cohorte_pct
				FROM agg a;




				/* ---------------------------------------------------------------------
                 V10. Liste d'alertes au dernier arrêté : créances en souffrance / saisies
                 --------------------------------------------------------------------- */  
				 
		CREATE OR REPLACE VIEW vw_alertes_creances AS
		WITH dernier AS (
		    SELECT MAX(date_arrete) AS date_ref FROM fait_expositions
		),
		historique AS (
		    SELECT e.*,
		           LAG(e.jours_retard, 3) OVER (PARTITION BY e.id_credit ORDER BY e.date_arrete) AS jours_retard_m3
		    FROM vw_exposition_enrichie e
		)
		SELECT
		    h.date_arrete, h.id_credit, h.id_client, h.nom_client, h.type_client, h.secteur_activite,
		    h.pays, h.region, h.ville, h.nom_agence, h.libelle_produit,
		    h.encours_capital, h.montant_impaye, h.jours_retard, h.statut_creance, h.note_risque,
		    h.provision_constituee, h.valeur_garantie, h.garantie_saisie, h.credit_restructure,
		    ROUND(100.0 * h.provision_constituee / NULLIF(h.encours_capital, 0), 1)      AS taux_provisionnement_pct,
		    ROUND(100.0 * h.valeur_garantie      / NULLIF(h.encours_capital, 0), 1)      AS couverture_garantie_pct,
		    CASE WHEN h.jours_retard - COALESCE(h.jours_retard_m3, 0) >= 90 THEN 'Aggravation rapide'
		         WHEN h.jours_retard >= 180                                   THEN 'Litigieux'
		         ELSE 'Douteux' END                                                       AS niveau_alerte,
		    RANK() OVER (ORDER BY h.encours_capital DESC)                                 AS rang_encours,
		    ROUND(100.0 * SUM(h.encours_capital) OVER (ORDER BY h.encours_capital DESC, h.id_credit
		                                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
		          / NULLIF(SUM(h.encours_capital) OVER (), 0), 1)                         AS part_cumulee_alertes_pct
		FROM historique h
		JOIN dernier d ON d.date_ref = h.date_arrete
		WHERE h.stage_ifrs9 = 3 OR h.garantie_saisie = 1;


		SELECT * FROM vw_synthese_annuelle ORDER BY perimetre, annee;

		SELECT * FROM vw_classement_agences WHERE date_arrete = "2025-12-31" ORDER BY rang_taux_npl_groupe LIMIT 10;

		SELECT * 
			FROM vw_classement_agences 
			WHERE date_arrete = '2025-12-31' 
			ORDER BY rang_taux_npl_groupe 
			LIMIT 10;



		


		
