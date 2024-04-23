#!/bin/bash

check_privileges() {
# Check user's permissions
if [[ $(id -u) != 0 ]]; then
    echo -e "${red}This script must be run as root.${reset}" >&2
    echo -e "${red}Please run the following command:${reset}" >&2
    echo -e "${red}sudo bash migrate.sh${reset}" >&2
    echo -e "${red}or run the script as the ${blue}root${reset} user${reset}" >&2
    echo -e "${red}su root${reset}" >&2

    # Prompt the user to retry with sudo
    echo -e "${yellow}Would you like to run the script with sudo? (y/n)${reset}"
    read -r answer
    if [[ $answer =~ ^[Yy]$ ]]; then
        exec sudo bash "$script_path/$script_name" "${args[@]}"
    else
        exit 1
    fi
fi
}

check_if_app_exists() {
    local appname=$1
    echo -e "${bold}Checking if app exists...${reset}"
    cli -m csv -c 'app chart_release query name' | tr -d " \t\r" | grep -qE "^${appname}$" 
}

check_health() {
    echo -e "${bold}Checking app health...${reset}"

    # Check if the namespace is either 'enterprise' or 'operators'
    catalog_train_label=$(k3s kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.catalog_train}')
    if [[ "$catalog_train_label" == "enterprise" || "$catalog_train_label" == "operators" ]]; then
        echo -e "${red}The namespace ${blue}'$namespace'${red} is configured under the ${blue}'$catalog_train_label'${red} train.${reset}"
        echo -e "${red}That train no longer exists, and you need to migrate to the new train.${reset}"
        echo -e "Please visit ${blue}https://truecharts.org/news/train-renames/${reset} and run the script."
        echo -e "Afterwards, you need to update that application then you can attempt the migration again."
        echo -e "If you want to force the migration, you can run the script with the ${blue}--force${reset} flag."
        echo -e "${red}Do not open a support ticket if you force the migration.${reset}"
        exit 1
    fi

    # Perform the empty edit to check the application health
    if output=$(cli -c "app chart_release update chart_release=\"$appname\" values={}" 2>&1); then
        # If the command succeeded, print nothing
        echo -e "${green}Passed${reset}\n"
    else
        # If the command failed, print the error output and advice
        echo -e "${red}Failed${reset}"
        echo "Output:"
        echo "$output"
        echo -e "${red}This was the result of performing an empty edit, you probably need to make changes in the chart edit configuration in the GUI.${reset}"
        echo -e "${red}Please resolve the issues above prior to running the migration.${reset}"
        echo -e "${red}Make sure to check Truecharts #announcements for migrations you may have missed.${reset}"
        echo -e "${red}If you want to force the migration, you can run the script with the ${blue}--force${reset} flag.${reset}"
        echo -e "${red}Do not open a support ticket if you force the migration.${reset}"
        exit 1
    fi
}

check_if_system_train() {
    echo -e "${bold}Checking if app is in the system train...${reset}"
    if midclt call chart.release.get_instance "$appname" | jq -r '.catalog_train' | grep -qE "^system$";then
        echo -e "${red}App is in the system train.${reset}"\
        "\nSystem train applications are rarely deleted,"\
        "\nlet alone migrated. Unless you are absolutely"\
        "\nsure, it is recommended to skip this application."\
        "\nDoing so can result in permanent loss of data and"\
        "\nconfiguration for various services and applications."\
        "\nIf you are 100% sure you want to migrate this application,"\
        "\nyou can do so by running the script with the ${blue}--force${reset} flag."
        exit 1
    else
        echo -e "${green}Passed${reset}\n"
    fi
}

check_filtered_apps() {
    # Define a function to process each app name
    process_app_name() {
        appname=$1

        # Run the command and directly check if the values are true, and include the reason
        midclt call chart.release.get_instance "$appname" | jq -r '
            if .config.operator.enabled == true then
                .name + ",operator"
            else
                empty
            end,
            if .config.cnpg.main.enabled == true then
                .name + ",cnpg"
            else
                empty
            end
            | select(length > 0)
        '
    }

    # Define a function to wait for a free slot in the semaphore
    wait_for_slot() {
        while true; do
            # Count the number of background jobs
            job_count=$(jobs -p | wc -l)

            # Check if there's a free slot
            if [[ $job_count -lt 5 ]]; then
                break
            fi

            # Wait for a short period before checking again
            sleep 0.1
        done
    }

    # Check if an array was passed as an argument
    if [ $# -eq 0 ]; then
        # Define the app names array using the command
        mapfile -t app_names < <(cli -m csv -c 'app chart_release query name' | tail -n +2 | sort | tr -d " \t\r" | awk 'NF')
    else
        # Use the passed array
        app_names=("$@")
    fi

    # Process the app names with a maximum of 5 concurrent processes
    for appname in "${app_names[@]}"; do
        wait_for_slot
        process_app_name "$appname" &
    done

    # Wait for any remaining jobs to finish
    wait
}
