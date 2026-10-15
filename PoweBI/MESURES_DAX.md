# Mesures DAX – Pilotage du risque de crédit (BECC)

> À coller dans Power BI Desktop (**Accueil > Nouvelle mesure**). Créez d'abord une table vide **`_Mesures`** (« Entrer des données ») pour y ranger toutes les mesures, par dossiers d'affichage.
> Modèle attendu : `dim_date`, `dim_agences`, `dim_clients`, `dim_produits`, `fait_expositions` (relations 1→\* de chaque dimension vers le fait ; `dim_date[date_complet]` → `fait_expositions[date_arrete]`).
> La table `dim_date` doit être **marquée comme table de dates** (colonne `date_complet`).

## 0. Colonnes calculées (une seule fois)

```dax
-- dim_date
Nom Mois = FORMAT ( dim_date[date_complet], "mmm" )                 -- trier par dim_date[mois]
Année-Mois = FORMAT ( dim_date[date_complet], "yyyy-mm" )
Libellé Trimestre = "T" & dim_date[trimestre] & " " & dim_date[annee]
Tri Trimestre = dim_date[annee] * 10 + dim_date[trimestre]          -- trier Libellé Trimestre par cette colonne

-- dim_clients
Bénéficiaire Risque =
IF ( dim_clients[groupe_economique] = "Hors groupe", dim_clients[nom_client], dim_clients[groupe_economique] )

-- dim_agences
Libellé Localisation = dim_agences[pays] & " | " & dim_agences[ville]
```

## 1. Paramètres de pilotage

```dax
Fonds Propres Réf = 30000000000          -- 30 Md XAF (à ajuster ; cohérent avec la vue SQL vw_grands_risques)
Seuil Grand Risque = 0.10
Seuil Alerte = 0.25
Plafond Individuel = 0.45
Seuil NPL Rouge = 0.12
Seuil NPL Orange = 0.08
```

## 2. Socle : mesures de stock (dernier arrêté de la période)

Les encours sont des **stocks** : on ne les additionne jamais dans le temps. Le motif ci-dessous prend le dernier arrêté mensuel disponible dans la période sélectionnée (mois, trimestre ou année).

```dax
Date Dernier Arrêté = MAX ( fait_expositions[date_arrete] )

Encours Total =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( SUM ( fait_expositions[encours_capital] ), fait_expositions[date_arrete] = d )

Encours NPL = CALCULATE ( [Encours Total], fait_expositions[stage_ifrs9] = 3 )
Encours Stage 2 = CALCULATE ( [Encours Total], fait_expositions[stage_ifrs9] = 2 )
Encours Sain = CALCULATE ( [Encours Total], fait_expositions[stage_ifrs9] = 1 )
Encours Restructuré = CALCULATE ( [Encours Total], fait_expositions[credit_restructure] = 1 )

Provisions Totales =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( SUM ( fait_expositions[provision_constituee] ), fait_expositions[date_arrete] = d )

Provisions Stage 3 = CALCULATE ( [Provisions Totales], fait_expositions[stage_ifrs9] = 3 )

Perte Attendue =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( SUM ( fait_expositions[perte_attendue] ), fait_expositions[date_arrete] = d )

Montant Impayé =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( SUM ( fait_expositions[montant_impaye] ), fait_expositions[date_arrete] = d )

Valeur Garanties =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( SUM ( fait_expositions[valeur_garantie] ), fait_expositions[date_arrete] = d )

Nb Crédits Actifs =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( DISTINCTCOUNT ( fait_expositions[id_credit] ), fait_expositions[date_arrete] = d )

Nb Clients Débiteurs =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( DISTINCTCOUNT ( fait_expositions[id_client] ), fait_expositions[date_arrete] = d )

Nb Crédits NPL = CALCULATE ( [Nb Crédits Actifs], fait_expositions[stage_ifrs9] = 3 )

Nb Garanties Saisies =
VAR d = [Date Dernier Arrêté]
RETURN CALCULATE ( COUNTROWS ( fait_expositions ), fait_expositions[garantie_saisie] = 1, fait_expositions[date_arrete] = d )
```

## 3. Indicateurs de qualité du portefeuille

```dax
Taux NPL % = DIVIDE ( [Encours NPL], [Encours Total] )
Taux Stage 2 % = DIVIDE ( [Encours Stage 2], [Encours Total] )
Taux Restructuration % = DIVIDE ( [Encours Restructuré], [Encours Total] )
Taux Couverture NPL % = DIVIDE ( [Provisions Stage 3], [Encours NPL] )
Taux Provisionnement Global % = DIVIDE ( [Provisions Totales], [Encours Total] )
Taux Perte Attendue % = DIVIDE ( [Perte Attendue], [Encours Total] )
Couverture Garantie % = DIVIDE ( [Valeur Garanties], [Encours Total] )
Couverture Garantie NPL % = DIVIDE ( CALCULATE ( [Valeur Garanties], fait_expositions[stage_ifrs9] = 3 ), [Encours NPL] )
Encours Net de Provisions = [Encours Total] - [Provisions Totales]
Encours (Md XAF) = DIVIDE ( [Encours Total], 1000000000 )
NPL (Md XAF) = DIVIDE ( [Encours NPL], 1000000000 )
Jours de Retard Moyen NPL =
CALCULATE ( AVERAGE ( fait_expositions[jours_retard] ), fait_expositions[stage_ifrs9] = 3,
            fait_expositions[date_arrete] = [Date Dernier Arrêté] )
```

## 4. Flux et coût du risque

```dax
Recouvrements = SUM ( fait_expositions[montant_recouvre] )
Passages en Perte = SUM ( fait_expositions[montant_passe_en_perte] )

-- Provisions à l'ouverture de la période (dernier arrêté précédent ; borné au premier arrêté disponible)
Provisions Ouverture =
VAR dMin   = MIN ( dim_date[date_complet] )
VAR dFirst = CALCULATE ( MIN ( fait_expositions[date_arrete] ), ALL ( fait_expositions ) )
VAR dRef   = MAX ( EOMONTH ( dMin, -1 ), dFirst )
RETURN CALCULATE ( SUM ( fait_expositions[provision_constituee] ),
                   REMOVEFILTERS ( dim_date ), fait_expositions[date_arrete] = dRef )

Dotation Nette Provisions = [Provisions Totales] - [Provisions Ouverture]

Coût du Risque = [Dotation Nette Provisions] + [Passages en Perte] - [Recouvrements]
Coût du Risque / Encours % = DIVIDE ( [Coût du Risque], [Encours Total] )
Taux de Recouvrement % = DIVIDE ( [Recouvrements], [Encours NPL] + [Recouvrements] )

-- Nouveaux NPL de la période (crédits en stage 3 à la fin de période, pas en stage 3 à l'ouverture)
Nouveaux NPL (Encours) =
VAR dMax   = [Date Dernier Arrêté]
VAR dMin   = MIN ( dim_date[date_complet] )
VAR dFirst = CALCULATE ( MIN ( fait_expositions[date_arrete] ), ALL ( fait_expositions ) )
VAR dRef   = MAX ( EOMONTH ( dMin, -1 ), dFirst )
VAR NplFin = CALCULATETABLE ( VALUES ( fait_expositions[id_credit] ),
                              fait_expositions[stage_ifrs9] = 3, fait_expositions[date_arrete] = dMax )
VAR NplDeb = CALCULATETABLE ( VALUES ( fait_expositions[id_credit] ),
                              fait_expositions[stage_ifrs9] = 3, fait_expositions[date_arrete] = dRef,
                              REMOVEFILTERS ( dim_date ) )
VAR Nouveaux = EXCEPT ( NplFin, NplDeb )
RETURN CALCULATE ( SUM ( fait_expositions[encours_capital] ), fait_expositions[date_arrete] = dMax, Nouveaux )
```

*Note : le premier mois de l'historique (janv. 2023) sert d'ouverture, donc le coût du risque de 2023 est calculé à partir de cet arrêté.*

## 5. Comparaisons temporelles

```dax
Encours Total N-1 = CALCULATE ( [Encours Total], SAMEPERIODLASTYEAR ( dim_date[date_complet] ) )
Var Encours vs N-1 % = DIVIDE ( [Encours Total] - [Encours Total N-1], [Encours Total N-1] )

Taux NPL N-1 % = CALCULATE ( [Taux NPL %], SAMEPERIODLASTYEAR ( dim_date[date_complet] ) )
Var Taux NPL vs N-1 (pts) = ( [Taux NPL %] - [Taux NPL N-1 %] ) * 100

Taux NPL Mois Précédent % = CALCULATE ( [Taux NPL %], DATEADD ( dim_date[date_complet], -1, MONTH ) )
Var Taux NPL MoM (pts) = ( [Taux NPL %] - [Taux NPL Mois Précédent %] ) * 100

Taux NPL Moyenne Mobile 3M =
AVERAGEX ( DATESINPERIOD ( dim_date[date_complet], MAX ( dim_date[date_complet] ), -3, MONTH ),
           CALCULATE ( [Taux NPL %], LASTDATE ( dim_date[date_complet] ) ) )
```

> `Taux NPL Moyenne Mobile 3M` : à utiliser sur un axe **mois** ; la moyenne porte sur 3 fins de mois (les jours sans arrêté renvoient BLANK et sont ignorés par AVERAGEX).

## 6. Concentration et grands risques (bénéficiaire = client ou groupe)

```dax
Exposition Max Bénéficiaire =
MAXX ( VALUES ( dim_clients[Bénéficiaire Risque] ), [Encours Total] )

Ratio Concentration Max % = DIVIDE ( [Exposition Max Bénéficiaire], [Fonds Propres Réf] )

Nb Grands Risques =
COUNTROWS ( FILTER ( VALUES ( dim_clients[Bénéficiaire Risque] ),
                     [Encours Total] >= [Seuil Grand Risque] * [Fonds Propres Réf] ) )

Nb Dépassements Plafond =
COUNTROWS ( FILTER ( VALUES ( dim_clients[Bénéficiaire Risque] ),
                     [Encours Total] >= [Plafond Individuel] * [Fonds Propres Réf] ) )

Total Grands Risques =
SUMX ( FILTER ( VALUES ( dim_clients[Bénéficiaire Risque] ),
                [Encours Total] >= [Seuil Grand Risque] * [Fonds Propres Réf] ),
       [Encours Total] )

Grands Risques / Fonds Propres % = DIVIDE ( [Total Grands Risques], [Fonds Propres Réf] )

Part Top 10 Débiteurs % =
VAR Top10 = TOPN ( 10, VALUES ( dim_clients[Bénéficiaire Risque] ), [Encours Total], DESC )
RETURN DIVIDE ( SUMX ( Top10, [Encours Total] ), [Encours Total] )

Ratio Fonds Propres Bénéficiaire % = DIVIDE ( [Encours Total], [Fonds Propres Réf] )

Statut Concentration =
SWITCH ( TRUE (),
    [Ratio Fonds Propres Bénéficiaire %] >= [Plafond Individuel],   "Dépassement plafond",
    [Ratio Fonds Propres Bénéficiaire %] >= [Seuil Alerte],         "Alerte rouge",
    [Ratio Fonds Propres Bénéficiaire %] >= [Seuil Grand Risque],   "Grand risque",
    "Normal" )
```

## 7. Classements et analyse géographique

```dax
Rang Agence (Taux NPL) =
RANKX ( ALLSELECTED ( dim_agences[nom_agence] ), [Taux NPL %], , DESC, DENSE )

Rang Pays (Taux NPL) =
RANKX ( ALLSELECTED ( dim_agences[pays] ), [Taux NPL %], , DESC, DENSE )

Part de l'Encours Groupe % =
DIVIDE ( [Encours Total], CALCULATE ( [Encours Total], ALLSELECTED ( dim_agences ) ) )

Part du NPL Groupe % =
DIVIDE ( [Encours NPL], CALCULATE ( [Encours NPL], ALLSELECTED ( dim_agences ) ) )

Indice de Sur-Risque =        -- > 1 : la zone pèse plus dans le NPL que dans l'encours
DIVIDE ( [Part du NPL Groupe %], [Part de l'Encours Groupe %] )
```

## 8. Mise en forme conditionnelle et titres dynamiques

```dax
Couleur KPI NPL =
SWITCH ( TRUE (),
    [Taux NPL %] >= [Seuil NPL Rouge],  "#C00000",
    [Taux NPL %] >= [Seuil NPL Orange], "#ED7D31",
    "#2E8B57" )

Flèche Tendance NPL =
VAR v = [Var Taux NPL vs N-1 (pts)]
RETURN IF ( ISBLANK ( v ), "", IF ( v > 0, "▲ ", IF ( v < 0, "▼ ", "■ " ) ) & FORMAT ( ABS ( v ), "0.0" ) & " pts vs N-1" )

Titre Dashboard = "Portefeuille au " & FORMAT ( [Date Dernier Arrêté], "dd/mm/yyyy" ) & " – montants en Md XAF"
```

## 9. Sécurité au niveau des lignes (RLS dynamique)

Créez une petite table `dim_securite` (`email`, `role`, `pays`, `id_agence`) et appliquez ces filtres de table :

```dax
-- Rôle « Chef d'agence » sur dim_agences
dim_agences[id_agence] =
    LOOKUPVALUE ( dim_securite[id_agence], dim_securite[email], USERPRINCIPALNAME () )

-- Rôle « Directeur régional / pays » sur dim_agences
dim_agences[pays] =
    LOOKUPVALUE ( dim_securite[pays], dim_securite[email], USERPRINCIPALNAME () )

-- Rôles « Direction générale » et « Comité de risques » : aucun filtre
```

## 10. Vérifications rapides (à comparer avec le SQL)

| Contrôle | Valeur attendue |
|---|---|
| `Encours (Md XAF)` au 31/12/2025, tous pays | ≈ 181,0 |
| `Taux NPL %` au 31/12/2025 | ≈ 8,4 % |
| `Taux NPL %` au 31/12/2024 | ≈ 16,0 % |
| `Taux Couverture NPL %` au 31/12/2025 | ≈ 72 % |
| `Nb Dépassements Plafond` au 31/12/2025 (FP = 30 Md) | 2 |
