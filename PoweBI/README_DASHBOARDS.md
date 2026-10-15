# Guide de construction des dashboards Power BI

Projet : pilotage du risque de crédit de **BECC – Banque Équatoriale du Crédit et du Commerce** (banque fictive, 6 pays CEMAC, 2023-2025).
Public : Direction générale, Comité de risques, directeurs pays/régions, chefs d'agence.

---

# 1. Préparation du modèle Power BI

# 1.1 Connexion et import
1. **Obtenir les données > PostgreSQL** (serveur, base `banque_risque`), mode **Importer**.
2. Importer les 5 tables : `dim_date`, `dim_agences`, `dim_clients`, `dim_produits`, `fait_expositions`.
3. Importer les vues utiles : `vw_synthese_mensuelle`, `vw_synthese_trimestrielle`, `vw_synthese_annuelle`, `vw_classement_agences`, `vw_top_clients_endettes`, `vw_grands_risques`, `vw_migration_stage`, `vw_garanties_recouvrements`, `vw_cohortes_octroi`, `vw_alertes_creances`.


# 1.2 Relations (schéma en étoile)
| De (1) | Vers (\*) | Direction |
|---|---|---|
| `dim_date[date_complet]` | `fait_expositions[date_arrete]` | Simple |
| `dim_agences[id_agence]` | `fait_expositions[id_agence]` | Simple |
| `dim_clients[id_client]` | `fait_expositions[id_client]` | Simple |
| `dim_produits[id_produit]` | `fait_expositions[id_produit]` | Simple |
| `dim_agences[id_agence]` | `dim_clients[id_agence]` | Simple (inactive si ambiguïté) |

Les vues SQL restent **isolées** (pas de relations) ou reliées uniquement à `dim_date` via leur colonne `date_arrete` ; elles alimentent des visuels précis (matrices, tableaux, cohortes).


# 2. Dashboard 1 – Vue exécutive du risque de crédit
**Pour qui :** Direction générale et Comité de risques. **Question :** « Où en est la qualité du portefeuille et à quel coût ? »

| Zone | Visuel | Champs / mesures | Remarques |
|---|---|---|---|
| Bandeau haut | 4 segments (listes déroulantes) | `dim_date[annee]`, `Libellé Trimestre`, `dim_agences[pays]`, `dim_produits[categorie_produit]` | Synchroniser sur toutes les pages |
| KPI (ligne de 6 cartes) | Cartes | `Encours (Md XAF)`, `Taux NPL %`, `Taux Couverture NPL %`, `Coût du Risque / Encours %`, `Taux Stage 2 %` |
| Gauche haut | Courbes et histogramme groupé | Axe `Année-Mois` ; colonnes `Encours (Md XAF)` ; ligne `Taux NPL %` | Axe secondaire pour la ligne |
| Droite haut | Graphique a barre empilé 100 % | Axe `Libellé Trimestre` ; valeurs `Encours Sain`, `Encours Stage 2`, `Encours NPL` | Montre la dégradation par stage |
| Gauche bas | Histogramme Empile | Axe `pays` ; valeur `Taux NPL %` ; info-bulle `Encours (Md XAF)`, `Couverture NPL` |
| Centre bas | Treemap | Groupe `secteur_activite` ; valeur `NPL (Md XAF)` | Repère les secteurs qui concentrent les impayés |
| Droite bas | Graphique en anneau | Catégorie `Libellé Trimestre` ; valeur `Coût du Risque` | Lire la poussée du coût du risque en 2024 |
| Pied | Tableau | `pays`, `Encours`, `NPL`, `Taux NPL %`, `Couverture`, `Coût du Risque` | Barres de données sur le taux NPL |

**Interactions :** clic sur un pays = filtre croisé de tous les visuels ; bouton « Réinitialiser » (signet).
**Lecture attendue sur le jeu fourni :** NPL 6,6 % fin 2023, **16,0 % fin 2024** (pic), 8,4 % fin 2025 ; couverture des NPL ≈ 72 % ; encours 144,9 → 175,9 → 181,0 Md XAF.

---

# 3. Dashboard 2 – Évolution et exposition dans le temps
**Pour qui :** Comité de risques, analystes. **Question :** « Comment le risque évolue par mois, trimestre, année, et d'où vient la dégradation ? »

| Visuel | Champs / mesures | Objectif |
|---|---|---|
| Courbes comparées | Axe `Nom Mois` ; `Taux NPL %` et `Taux NPL %` ; légende `annee` | Saisonnalité et comparaison année sur année |
| Matrice thermique | Lignes `pays` ; colonnes `Libellé Trimestre` ; valeur `Taux NPL %` ; mise en forme par échelle de couleurs | Voir quel pays se dégrade et quand |
| Histogramme + courbe | Axe `Année-Mois` ; `Nouveaux NPL (Encours)` en colonnes, `Recouvrements` en ligne | Flux d'entrées en défaut vs récupérations |
| Aires empilées | Axe `Année-Mois` ; valeurs `Encours Total` ; légende `categorie_produit` | Mix d'exposition par produit |
| Matrice de cohortes | Source `vw_cohortes_octroi` ; lignes `libelle_cohorte` ; colonnes `mois_depuis_octroi` ; valeur `taux_npl_pct` ; échelle de couleurs | Qualité des crédits octroyés par période (vintages) |

| Arbre de décomposition | Analyser `Encours NPL` par `pays`, `secteur_activite`, `categorie_produit`, `ville` | Exploration guidée des causes |

**Boutons de bascule (signets) :** Mois / Trimestre / Année – utiliser un paramètre de champ sur l'axe (`Nom Mois`, `Libellé Trimestre`, `annee`).
**Lecture attendue :** trimestre le plus tendu = T4 2024 (NPL 16,0 %) ; en fin 2025 la RCA reste à 27,3 % et le Tchad à 15,1 % tandis que le Cameroun redescend à 4,2 % (18,2 % fin 2024).

---

# 4. Dashboard 3 – Pilotage, alertes et grands risques
**Pour qui :** Direction des risques, recouvrement. **Question :** « Quelles expositions et quels dossiers exigent une décision cette semaine ? »

| Visuel | Champs / mesures | Objectif |
|---|---|---|
| Cartes KPI | `Nb Grands Risques`, `Nb Dépassements Plafond`, `Grands Risques / Fonds Propres %`, `Part Top 10 Débiteurs %`, `Nb Garanties Saisies`, `Couverture Garantie NPL %` | Tableau d'alerte |
| Barres Top 15 | Axe `Bénéficiaire Risque` (filtre Top N sur `Encours Total`) ; valeur `Ratio Fonds Propres Bénéficiaire %` ; lignes constantes à 10 %, 25 %, 45 % | Concentration par client ou groupe |
| Graphique a barre Groupé| Source `vw_top_clients_endettes` ; axe `rang_encours` ; ligne `part_cumulee_pct` | Montrer la dépendance aux plus gros débiteurs |
| Graphique Empilé| X `Encours Total`, Y `Taux NPL %`, détail `secteur_activite`, taille `Provisions Totales` | Repérer les secteurs à fort encours et fort risque |
| Tableau d'alertes | Source `vw_alertes_creances` : `nom_client`, `ville`, `libelle_produit`, `encours_capital`, `jours_retard`, `niveau_alerte`, `couverture_garantie_pct`, `taux_provisionnement_pct` | Liste opérationnelle triée par encours |
| Barres comparées | Source `vw_garanties_recouvrements` : `couverture_garantie_npl_pct` par `categorie_produit` | Produits dont la garantie est insuffisante |

**Mise en forme conditionnelle :** `niveau_alerte` (rouge « Aggravation rapide », orange « Litigieux », jaune « Douteux ») ; `couverture_garantie_pct` < 100 % en rouge.
**Navigation :** *drill-through* « Fiche client » (page masquée avec `nom_client` en filtre : historique des retards, garanties, provisions) ; info-bulle de page sur le bénéficiaire (évolution du ratio fonds propres).
**Lecture attendue :** au 31/12/2025, **22 bénéficiaires** dépassent 10 % des fonds propres de référence (30 Md XAF) ; **2 groupes dépassent le plafond de 45 %** (Groupe Ogooué Energies 49,0 % ; Groupe Mayombe Invest 48,8 %) ; les 10 premiers bénéficiaires pèsent 51,3 % de l'encours ; 39 crédits sont en NPL et 42 garanties sont en cours de réalisation.

---

# 5. Dashboard 4 – Cartographie géographique et agences
**Pour qui :** Directeurs régionaux, chefs d'agence. **Question :** « Quelles zones et quelles agences concentrent le risque ? »

| Visuel | Champs / mesures | Objectif |
|---|---|---|
| Grqphique en courbe |  taille `Encours NPL`, couleur `Taux NPL %`, info-bulle `ville`, `pays` | Cartographie du risque sur 6 pays |
| Matrice hiérarchique | Lignes `pays > region > ville > nom_agence` ; valeurs `Encours (Md XAF)`, `NPL (Md XAF)`, `Taux NPL %`, `Couverture NPL`, `Rang Agence (Taux NPL)` | Exploration par niveau |
| Barres Top 10 agences | Axe `nom_agence` ; valeur `Taux NPL %` ; filtre `Encours Total` > 1 Md XAF | Agences les plus risquées |

| Tableau de classement | Source `vw_classement_agences` : `rang_taux_npl_pays`, `quartile_risque`, `niveau_risque`, `pareto_npl_cumule_pct` | Priorisation des plans d'action |

**Sécurité (RLS) :** chef d'agence = sa propre agence ; directeur régional = son pays ; Direction générale et Comité = tout. Tester avec **Affichage > Afficher en tant que**.
**Lecture attendue :** au 31/12/2025, Bangui Plateau (53,3 % de NPL, 5,3 Md XAF) et N'Djamena Plateau (25,6 %) arrivent en tête ; N'Djamena (33,3 Md d'encours, NPL 17,0 %) et Bangui (11,5 Md, NPL 46,1 %) concentrent l'essentiel des créances en souffrance, loin devant Douala (4,8 %).

---

# 6. Données par axe d'analyse

| Axe | Colonnes | Source |
|---|---|---|
| Temps | `annee`, `trimestre`, `mois`, `date_complet` | `dim_date` |
| Géographie | `pays`, `region`, `ville`, `nom_agence` | `dim_agences` |
| Client | `type_client`, `segment`, `secteur_activite`, `groupe_economique`, `note_interne_initiale` | `dim_clients` |
| Produit | `libelle_produit`, `categorie_produit`, `garantie_type` | `dim_produits` |
| Risque | `stage_ifrs9`, `statut_creance`, `note_risque`, `jours_retard` | `fait_expositions` |

# 7. Bonnes pratiques de publication
- Une page = une décision ; pas plus de 6 KPI et 8 visuels par page.
- Mêmes couleurs partout pour les mêmes statuts (vert / orange / rouge).
- Désactiver les interactions inutiles (menu **Format > Modifier les interactions**).
- Vérifier les performances (**Affichage > Analyseur de performances**) ; privilégier les mesures aux colonnes calculées.
- Planifier l'actualisation (mensuelle, après l'arrêté comptable) via la passerelle de données.
