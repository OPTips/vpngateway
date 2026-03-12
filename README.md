# Proxmox VPN Gateway (WireGuard + Kill Switch + DHCP)

Ce projet permet de déployer rapidement une machine virtuelle (VM) sous Proxmox agissant comme un routeur VPN hautement sécurisé. Toute machine virtuelle connectée à son réseau isolé verra son trafic obligatoirement chiffré et routé à travers le tunnel WireGuard, sans configuration manuelle côté client.

## Fonctionnalités principales

* **Agnostique :** Compatible avec n'importe quel fournisseur VPN utilisant WireGuard (AirVPN, Mullvad, ProtonVPN, etc.).
* **Kill Switch strict (IPv4 & IPv6) :** Blocage instantané de tout trafic hors du tunnel VPN via `iptables`.
* **Serveur DHCP intégré :** Distribution automatique d'adresses IP et du serveur DNS du fournisseur VPN aux machines clientes via `dnsmasq`.
* **Anti-fuites DNS :** Redirection forcée des requêtes DNS dans le tunnel.
* **Amnésique (No-Log) :** Stockage des journaux (`journald`) en mémoire vive (RAM) limité à 50 Mo, désactivation des historiques DHCP et suppression de l'historique `bash`. Le système s'oublie à chaque redémarrage.

---

## 1. Prérequis (Environnement Proxmox)

Avant d'installer la VM Gateway, vous devez préparer l'architecture réseau dans Proxmox :

1. Connectez-vous à l'interface web de Proxmox.
2. Allez dans **[Votre Nœud] > System > Network**.
3. Créez un nouveau **Linux Bridge** (ex: `vmbr1`).
4. **Ne lui attribuez aucune adresse IP** et ne le liez à aucun port physique (laissez `Bridge ports` vide). Il s'agit de votre réseau isolé (LAN).
5. Appliquez la configuration réseau (`Apply Configuration`).

Vous devez également disposer d'un **fichier de configuration WireGuard valide (`.conf`)** fourni par votre fournisseur VPN.

---

## 2. Configuration de la VM Gateway

Créez une nouvelle machine virtuelle (Debian ou Ubuntu Server recommandés) avec les spécifications suivantes :

* **Ressources :** 1 à 2 Go de RAM, 1 à 2 cœurs CPU, 10 Go de disque.
* **Réseau (Important) :** La VM doit posséder **deux cartes réseau**.
* `net0` (WAN) : Connectée au pont principal ayant accès à internet (généralement `vmbr0`).
* `net1` (LAN) : Connectée à votre pont isolé (ex: `vmbr1`).



Installez l'OS de base (sans interface graphique) et connectez-vous en SSH ou via la console Proxmox en tant que `root` (ou un utilisateur avec les droits `sudo`).

---

## 3. Déploiement du script

### Étape 3.1 : Création du fichier

Créez le script d'initialisation en utilisant `vi` :

```bash
sudo vi /root/init-vpn-gateway.sh
```

Passez en mode insertion, collez le code du script d'initialisation, puis sauvegardez et quittez (`Échap`, puis `:wq`).

### Étape 3.2 : Exécution

Rendez le script exécutable et lancez-le :

```bash
sudo chmod +x /root/init-vpn-gateway.sh
sudo /root/init-vpn-gateway.sh
```

### Étape 3.3 : Processus interactif

Le script vous guidera à travers les étapes suivantes :

1. **Sélection de l'interface interne :** Le script listera les cartes réseau disponibles. Tapez le numéro correspondant à votre interface isolée (LAN).
2. **Configuration WireGuard :** Copiez l'intégralité du texte de votre fichier `.conf` (depuis votre ordinateur). Collez-le dans la console, appuyez sur `Entrée` pour aller à la ligne, puis pressez `Ctrl+D` pour valider.
3. **Redémarrage automatique :** Le script va installer les paquets, configurer le pare-feu, le DHCP et les règles No-Log, puis redémarrera la VM pour tout appliquer proprement.

---

## 4. Utilisation

### Connecter de nouvelles machines

Pour router n'importe quelle VM existante ou future via ce VPN :

1. Dans Proxmox, allez dans la configuration matérielle (`Hardware`) de la VM cliente.
2. Assignez sa carte réseau au pont isolé (ex: `vmbr1`).
3. Démarrez la VM. Elle recevra automatiquement une IP (dans la plage `10.99.0.x`) et tout son trafic sera chiffré.

### Mettre à jour l'IP du serveur VPN

Si vous souhaitez changer de serveur ou de pays (chez le même fournisseur), un utilitaire est préinstallé. Connectez-vous à la console de la Gateway et tapez :

```bash
sudo update-vpn-ip <nouvelle_ip_du_serveur>
```

*Le script mettra à jour la configuration, ajustera le pare-feu, et relancera le tunnel sans nécessiter de redémarrage.*
