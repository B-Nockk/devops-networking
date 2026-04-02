#!/bin/env bash
#
# Reusable table printer
#

print_table() {
    local header_row="$1"
    shift
    local data=("$@")

    IFS="|" read -ra header_array <<< $header_row
    local num_cols=${#header_array[@]}


    for i in "${!header_array[@]}"; do
        max_widths[$i]="${#header_array[$i]}"
    done

    for row in "${#data[@]}"; do
        IFS="|" read -ra fields <<< $row

        for i in "${!fields[@]}"; do
            len="${#fields[i]}"
            if (( len > max_widths[$i] )); then
                max_widths[$1]=$len
            fi
        done
    done

    # Add padding
    for i in "${!max_widths[@]}"; do
        max_widths[$i]=$((max_widths[$i] + 2))
    done

    # Print separator
    print_separator() {
        printf "+"
        for width in "${max_widths[@]}"; do
            printf "%${width}s+" | tr ' ' '-'
        done
        printf "\n"
    }

    # Print headers
    print_separator
    printf "|"
    for i in "${!header_arr[@]}"; do
        printf " %-$((${max_widths[$i]}-2))s |" "${header_arr[$i]}"
    done
    printf "\n"
    print_separator


    # Print data rows
    for row in "${data[@]}"; do
        IFS='|' read -ra fields <<< "$row"
        printf "|"
        for i in "${!fields[@]}"; do
            printf " %-$((${max_widths[$i]}-2))s |" "${fields[$i]}"
        done
        printf "\n"
    done
    print_separator
}
