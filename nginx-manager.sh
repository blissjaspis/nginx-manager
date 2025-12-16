#!/bin/bash

# nginx-manager.sh - Easy nginx configuration generator
# Version: 1.1.0

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
TEMPLATES_DIR="$(dirname "$0")/templates"

print_color() {
    echo -e "${1}${2}${NC}"
}

print_banner() {
    clear
    print_color "$CYAN" "╔══════════════════════════════════════════════════════════╗"
    print_color "$CYAN" "║                    nginx-manager                         ║"
    print_color "$CYAN" "║              Easy nginx configuration tool               ║"
    print_color "$CYAN" "╚══════════════════════════════════════════════════════════╝"
    echo
}

check_nginx() {
    if ! command -v nginx &> /dev/null; then
        print_color "$RED" "nginx is not installed. Please install nginx first."
        exit 1
    fi
}

validate_domain() {
    local domain=$1
    [[ $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

# Sanitize domain for use in nginx upstream names (replace dots with underscores)
sanitize_upstream_name() {
    echo "${1//./_}"
}

test_nginx_config() {
    print_color "$BLUE" "Testing nginx configuration..."
    if sudo nginx -t; then
        print_color "$GREEN" "✓ nginx configuration is valid"
        return 0
    else
        print_color "$RED" "✗ nginx configuration has errors"
        return 1
    fi
}

reload_nginx() {
    print_color "$BLUE" "Reloading nginx..."
    if sudo systemctl reload nginx 2>/dev/null || sudo service nginx reload 2>/dev/null; then
        print_color "$GREEN" "✓ nginx reloaded successfully"
    else
        print_color "$RED" "✗ Failed to reload nginx"
    fi
}

generate_ssl() {
    local domain=$1
    local email=$2
    local www_enabled=$3

    if ! command -v certbot &> /dev/null; then
        print_color "$YELLOW" "Certbot not found. Install certbot to auto-generate SSL certificates."
        return 1
    fi

    print_color "$BLUE" "Generating SSL certificate for $domain..."
    if [[ "$www_enabled" == "yes" ]]; then
        sudo certbot --nginx -d "$domain" -d "www.$domain" --email "$email" --agree-tos --non-interactive
    else
        sudo certbot --nginx -d "$domain" --email "$email" --agree-tos --non-interactive
    fi
}

create_site_config() {
    local site_type=$1
    local domain=$2
    local root_path=$3
    local php_version=$4
    local port=$5
    local ssl_enabled=$6
    local email=$7
    local www_enabled=$8
    local www_is_main=$9

    local template_file="$TEMPLATES_DIR/${site_type}.conf"
    local config_file="$NGINX_SITES_AVAILABLE/$domain"
    local upstream_name
    upstream_name=$(sanitize_upstream_name "$domain")

    if [[ ! -f "$template_file" ]]; then
        print_color "$RED" "Template file not found: $template_file"
        return 1
    fi

    # Read and substitute template variables
    local config_content
    config_content=$(cat "$template_file")

    config_content=${config_content//\{\{LOG_DOMAIN\}\}/$domain}
    config_content=${config_content//\{\{ROOT_PATH\}\}/$root_path}
    config_content=${config_content//\{\{PHP_VERSION\}\}/$php_version}
    config_content=${config_content//\{\{PORT\}\}/$port}
    config_content=${config_content//\{\{UPSTREAM_NAME\}\}/$upstream_name}

    # Handle www subdomain
    if [[ "$www_enabled" == "yes" ]]; then
        if [[ "$www_is_main" == "yes" ]]; then
            config_content=${config_content//\{\{DOMAIN\}\}/www.$domain}
            config_content=${config_content//\{\{REDIRECT_BLOCK\}\}/"# Redirect naked domain to www
server {
    listen 80;
    server_name $domain;
    return 301 \$scheme://www.$domain\$request_uri;
}"}
        else
            config_content=${config_content//\{\{DOMAIN\}\}/$domain}
            config_content=${config_content//\{\{REDIRECT_BLOCK\}\}/"# Redirect www to naked domain
server {
    listen 80;
    server_name www.$domain;
    return 301 \$scheme://$domain\$request_uri;
}"}
        fi
    else
        config_content=${config_content//\{\{DOMAIN\}\}/$domain}
        config_content=${config_content//\{\{REDIRECT_BLOCK\}\}/}
    fi

    # Write configuration
    echo "$config_content" | sudo tee "$config_file" > /dev/null
    sudo ln -sf "$config_file" "$NGINX_SITES_ENABLED/"
    print_color "$GREEN" "✓ Site configuration created: $config_file"

    # Test and optionally setup SSL
    if test_nginx_config; then
        if [[ "$ssl_enabled" == "yes" && -n "$email" ]]; then
            if generate_ssl "$domain" "$email" "$www_enabled"; then
                print_color "$GREEN" "✓ SSL enabled for $domain"
            fi
        fi
        reload_nginx
        print_color "$GREEN" "✓ Site $domain is now active!"
    else
        print_color "$RED" "Configuration has errors. Please check and try again."
    fi
}

create_site_interactive() {
    print_color "$CYAN" "=== Create New Site Configuration ==="
    echo
    print_color "$CYAN" "Select site type:"
    echo "1) Laravel PHP Application"
    echo "2) Static HTML/CSS/JS Website"
    echo "3) Node.js Application"
    echo "4) WordPress Site"
    echo "5) Single Page Application (SPA)"
    echo "6) Reverse Proxy"
    echo
    read -p "Enter choice (1-6): " site_type_choice

    case $site_type_choice in
        1) site_type="laravel" ;;
        2) site_type="static" ;;
        3) site_type="nodejs" ;;
        4) site_type="wordpress" ;;
        5) site_type="spa" ;;
        6) site_type="proxy" ;;
        *) print_color "$RED" "Invalid choice"; return 1 ;;
    esac

    # Domain input
    while true; do
        read -p "Enter domain name (e.g., example.com): " domain
        if validate_domain "$domain"; then
            break
        fi
        print_color "$RED" "Invalid domain name. Please try again."
    done

    # Root path (not needed for proxy)
    root_path=""
    if [[ "$site_type" != "proxy" ]]; then
        read -p "Enter document root path (default: /var/www/$domain): " root_path
        root_path=${root_path:-/var/www/$domain}
    fi

    # PHP version for Laravel/WordPress
    php_version="8.2"
    if [[ "$site_type" == "laravel" || "$site_type" == "wordpress" ]]; then
        read -p "Enter PHP version (default: 8.2): " php_input
        php_version=${php_input:-8.2}
    fi

    # Port for Node.js/Proxy
    port="3000"
    if [[ "$site_type" == "nodejs" || "$site_type" == "proxy" ]]; then
        read -p "Enter application port (default: 3000): " port_input
        port=${port_input:-3000}
    fi

    # SSL configuration
    ssl_enabled="no"
    email=""
    read -p "Enable SSL with Let's Encrypt? (y/n): " ssl_choice
    if [[ "$ssl_choice" =~ ^[Yy] ]]; then
        ssl_enabled="yes"
        read -p "Enter email for Let's Encrypt: " email
    fi

    # www subdomain configuration
    www_enabled="no"
    www_is_main="no"
    read -p "Include www subdomain? (y/n): " www_choice
    if [[ "$www_choice" =~ ^[Yy] ]]; then
        www_enabled="yes"
        echo
        print_color "$YELLOW" "Which domain should be the main one?"
        echo "1) Naked domain (${domain}) - redirect www to naked"
        echo "2) www domain (www.${domain}) - redirect naked to www"
        read -p "Choose (1 or 2): " main_choice
        [[ "$main_choice" == "2" ]] && www_is_main="yes"
    fi

    # Confirmation
    echo
    print_color "$YELLOW" "=== Configuration Summary ==="
    print_color "$CYAN" "Site Type: $site_type"
    print_color "$CYAN" "Domain: $domain"
    [[ -n "$root_path" ]] && print_color "$CYAN" "Root Path: $root_path"
    [[ "$site_type" == "laravel" || "$site_type" == "wordpress" ]] && print_color "$CYAN" "PHP Version: $php_version"
    [[ "$site_type" == "nodejs" || "$site_type" == "proxy" ]] && print_color "$CYAN" "Port: $port"
    print_color "$CYAN" "SSL Enabled: $ssl_enabled"
    [[ -n "$email" ]] && print_color "$CYAN" "Email: $email"
    print_color "$CYAN" "www Subdomain: $www_enabled"
    if [[ "$www_enabled" == "yes" ]]; then
        if [[ "$www_is_main" == "yes" ]]; then
            print_color "$CYAN" "Main Domain: www.${domain} (naked redirects to www)"
        else
            print_color "$CYAN" "Main Domain: ${domain} (www redirects to naked)"
        fi
    fi
    echo

    read -p "Continue? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        print_color "$YELLOW" "Operation cancelled."
        return 0
    fi

    create_site_config "$site_type" "$domain" "$root_path" "$php_version" "$port" "$ssl_enabled" "$email" "$www_enabled" "$www_is_main"
}

list_sites() {
    print_color "$CYAN" "=== Nginx Sites ==="
    echo

    if [[ -d "$NGINX_SITES_AVAILABLE" ]]; then
        print_color "$CYAN" "Available sites:"
        for site in "$NGINX_SITES_AVAILABLE"/*; do
            if [[ -f "$site" ]]; then
                local site_name
                site_name=$(basename "$site")
                local status="disabled"
                [[ -L "$NGINX_SITES_ENABLED/$site_name" ]] && status="enabled"
                printf "  %-30s [%s]\n" "$site_name" "$status"
            fi
        done
    fi
    echo
}

remove_site() {
    list_sites
    read -p "Enter site name to remove: " site_name

    if [[ -f "$NGINX_SITES_AVAILABLE/$site_name" ]]; then
        read -p "Are you sure you want to remove $site_name? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
            sudo rm -f "$NGINX_SITES_ENABLED/$site_name"
            sudo rm -f "$NGINX_SITES_AVAILABLE/$site_name"
            print_color "$GREEN" "✓ Site $site_name removed"
            reload_nginx
        fi
    else
        print_color "$RED" "Site $site_name not found"
    fi
}

main_menu() {
    while true; do
        print_banner
        print_color "$CYAN" "Choose an option:"
        echo "1) Create new site configuration"
        echo "2) List existing sites"
        echo "3) Remove site"
        echo "4) Test nginx configuration"
        echo "5) Reload nginx"
        echo "6) Exit"
        echo
        read -p "Enter choice (1-6): " choice

        case $choice in
            1) create_site_interactive ;;
            2) list_sites ;;
            3) remove_site ;;
            4) test_nginx_config ;;
            5) reload_nginx ;;
            6) print_color "$GREEN" "Goodbye!"; exit 0 ;;
            *) print_color "$RED" "Invalid choice" ;;
        esac
        read -p "Press Enter to continue..."
    done
}

main() {
    check_nginx

    if [[ $# -eq 0 ]]; then
        main_menu
    else
        case $1 in
            create) create_site_interactive ;;
            list) list_sites ;;
            test) test_nginx_config ;;
            reload) reload_nginx ;;
            *) echo "Usage: $0 [create|list|test|reload]"; echo "Run without arguments for interactive mode." ;;
        esac
    fi
}

main "$@"
