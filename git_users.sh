#!/bin/bash

# Получаем реального пользователя (того, кто запустил sudo)
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Файл для хранения конфигурации пользователей
CONFIG_DIR="$REAL_HOME/.config/git-users"
CONFIG_FILE="$CONFIG_DIR/config.json"
USERS_DIR="$CONFIG_DIR/commands"

# Создаем директории для конфигурации
mkdir -p "$CONFIG_DIR"
mkdir -p "$USERS_DIR"
chown -R "$REAL_USER" "$CONFIG_DIR"

# Функция для поиска существующих git-пользователей
find_git_users() {
    local users=()
    local global_config="$REAL_HOME/.gitconfig"
    local xdg_config="$REAL_HOME/.config/git/config"
    local repo_configs=$(sudo -u "$REAL_USER" find "$REAL_HOME" -type f -name "config" -path "**/.git/*" 2>/dev/null)

    echo -e "${BLUE}Поиск существующих git-пользователей...${NC}"

    # Проверяем глобальный конфиг
    if [ -f "$global_config" ]; then
        local name=$(git config -f "$global_config" user.name)
        local email=$(git config -f "$global_config" user.email)
        if [ ! -z "$name" ] && [ ! -z "$email" ]; then
            users+=("$name:$email:global")
        fi
    fi

    # Проверяем XDG конфиг
    if [ -f "$xdg_config" ]; then
        local name=$(git config -f "$xdg_config" user.name)
        local email=$(git config -f "$xdg_config" user.email)
        if [ ! -z "$name" ] && [ ! -z "$email" ]; then
            users+=("$name:$email:xdg")
        fi
    fi

    # Проверяем локальные репозитории
    while IFS= read -r config; do
        if [ -f "$config" ]; then
            local name=$(git config -f "$config" user.name)
            local email=$(git config -f "$config" user.email)
            if [ ! -z "$name" ] && [ ! -z "$email" ]; then
                local repo_path=$(dirname $(dirname "$config"))
                users+=("$name:$email:${repo_path##*/}")
            fi
        fi
    done <<< "$repo_configs"

    # Выводим найденных пользователей
    if [ ${#users[@]} -eq 0 ]; then
        echo -e "${YELLOW}Существующих git-пользователей не найдено${NC}"
        return
    fi

    echo -e "${GREEN}Найдены следующие git-пользователи:${NC}"
    printf '%s\n' "${users[@]}" | sort -u | while IFS=: read -r name email source; do
        echo -e "Имя: ${BLUE}$name${NC}"
        echo -e "Email: ${BLUE}$email${NC}"
        echo -e "Источник: ${YELLOW}$source${NC}"
        echo "------------------------"
    done
}

# Функция для загрузки существующей конфигурации
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo "{}"
    fi
}

# Функция для сохранения конфигурации
save_config() {
    echo "$1" > "$CONFIG_FILE"
    chown "$REAL_USER" "$CONFIG_FILE"
}

# Функция для добавления пользователя
add_user() {
    local command_suffix=$1
    local display_name=$2
    local git_username=$3
    local email=$4

    local config=$(load_config)
    local new_user="{\"git_username\": \"$git_username\", \"email\": \"$email\", \"display_name\": \"$display_name\"}"

    # Добавляем пользователя в конфигурацию
    config=$(echo "$config" | jq ".\"git-$command_suffix\" = $new_user")
    save_config "$config"

    # Создаем команду переключения
    create_user_switch_command "git-$command_suffix" "$git_username" "$email" "$display_name"

    # Обновляем хуки после добавления пользователя
    update_hooks

    echo -e "${GREEN}Пользователь успешно добавлен${NC}"
}

# Функция для удаления пользователя
remove_user() {
    local command_suffix=$1

    local config=$(load_config)

    # Удаляем пользователя из конфигурации
    config=$(echo "$config" | jq "del(.\"git-$command_suffix\")")
    save_config "$config"

    # Удаляем команду переключения
    rm -f "$USERS_DIR/git-$command_suffix"
    rm -f "/usr/local/bin/git-$command_suffix"

    # Обновляем хуки после удаления пользователя
    update_hooks

    echo -e "${GREEN}Пользователь успешно удален${NC}"
}

# Функция для изменения пользователя
modify_user() {
    local command_suffix=$1
    local display_name=$2
    local git_username=$3
    local email=$4

    # Сначала удаляем старую конфигурацию
    remove_user "$command_suffix"

    # Затем добавляем новую
    add_user "$command_suffix" "$display_name" "$git_username" "$email"

    echo -e "${GREEN}Пользователь успешно изменен${NC}"
}

# Функция для отображения списка пользователей
list_users() {
    local config=$(load_config)

    echo -e "${BLUE}Список настроенных пользователей Git:${NC}"
    echo "$config" | jq -r 'to_entries | .[] | "\(.key): \(.value.display_name) <\(.value.email)>"'
}

# Функция для интерактивного меню
show_menu() {
    while true; do
        echo -e "\n${BLUE}Управление пользователями Git${NC}"
        echo "1. Показать список настроенных пользователей"
        echo "2. Найти существующих git-пользователей"
        echo "3. Добавить пользователя"
        echo "4. Изменить пользователя"
        echo "5. Удалить пользователя"
        echo "6. Обновить pre-commit хуки"
        echo "0. Выход"

        read -p "Выберите действие: " choice

        case $choice in
            1)
                list_users
                ;;
            2)
                find_git_users
                ;;
            3)
                read -p "Введите имя для команды (без git-): " command_suffix
                read -p "Введите отображаемое имя: " display_name
                read -p "Введите email: " email
                read -p "Введите имя пользователя для git [$display_name]: " git_username
                git_username=${git_username:-$display_name}

                if validate_email "$email"; then
                    add_user "$command_suffix" "$display_name" "$git_username" "$email"
                fi
                ;;
            4)
                read -p "Введите имя команды для изменения (без git-): " command_suffix
                if [ -f "$USERS_DIR/git-$command_suffix" ]; then
                    read -p "Введите новое отображаемое имя: " display_name
                    read -p "Введите новый email: " email
                    read -p "Введите новое имя пользователя для git [$display_name]: " git_username
                    git_username=${git_username:-$display_name}

                    if validate_email "$email"; then
                        modify_user "$command_suffix" "$display_name" "$git_username" "$email"
                    fi
                else
                    echo -e "${RED}Пользователь не найден${NC}"
                fi
                ;;
            5)
                read -p "Введите имя команды для удаления (без git-): " command_suffix
                if [ -f "$USERS_DIR/git-$command_suffix" ]; then
                    remove_user "$command_suffix"
                else
                    echo -e "${RED}Пользователь не найден${NC}"
                fi
                ;;
            6)
                update_hooks
                ;;
            0)
                echo -e "${GREEN}Настройка завершена!${NC}"
                echo -e "${BLUE}Для применения изменений выполните:${NC}"
                echo "source ~/.bashrc"
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор${NC}"
                ;;
        esac
    done
}

# Добавим функцию для валидации email
validate_email() {
    local email=$1
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo -e "${RED}Ошибка: Некорректный email адрес${NC}"
        return 1
    fi
    return 0
}

# Функция для получения информации о пользователе
get_user_info() {
    local name=$1
    local default_email=$2

    echo -e "${BLUE}Настройка пользователя: $name${NC}"

    # Спрашиваем email с валидацией
    while true; do
        if [ -z "$default_email" ]; then
            read -p "Введите email для $name: " email
        else
            read -p "Email для $name [$default_email]: " email
            email=${email:-$default_email}
        fi

        if validate_email "$email"; then
            break
        fi
    done

    # Валидация имени пользователя
    while true; do
        read -p "Введите имя пользователя для git [$name]: " git_username
        git_username=${git_username:-$name}

        if [[ "$git_username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            break
        else
            echo -e "${RED}Ошибка: Имя пользователя может содержать только буквы, цифры, точки, подчеркивания и дефисы${NC}"
        fi
    done

    echo "$git_username:$email"
}

# Функция для создания команды переключения пользователя
create_user_switch_command() {
    local command_name=$1
    local git_username=$2
    local email=$3
    local display_name=$4

    cat > "$USERS_DIR/$command_name" << EOL
#!/bin/bash
git config --global user.name "$git_username"
git config --global user.email "$email"
echo "Git настроен для пользователя $display_name"
echo "Name: $git_username"
echo "Email: $email"
EOL

    chmod +x "$USERS_DIR/$command_name"
    chown "$REAL_USER" "$USERS_DIR/$command_name"

    # Создаем символическую ссылку в /usr/local/bin
    ln -sf "$USERS_DIR/$command_name" "/usr/local/bin/$command_name"
}

# Функция для обновления pre-commit хуков
update_hooks() {
    echo -e "${BLUE}Обновление pre-commit хуков...${NC}"

    # Создаем директорию для git-templates
    local templates_dir="$CONFIG_DIR/git-templates"
    mkdir -p "$templates_dir/hooks"
    chown -R "$REAL_USER" "$templates_dir"

    # Создаем pre-commit хук
    cat > "$templates_dir/hooks/pre-commit" << 'EOL'
#!/bin/bash

# Получаем текущие настройки Git
CURRENT_NAME=$(git config user.name)
CURRENT_EMAIL=$(git config user.email)

# Проверяем наличие настроек
if [ -z "$CURRENT_NAME" ] || [ -z "$CURRENT_EMAIL" ]; then
    echo "ВНИМАНИЕ! Git пользователь не настроен!"
    echo "Доступные команды:"
EOL

    # Загружаем конфигурацию
    local config=$(load_config)

    # Добавляем список пользователей в pre-commit хук
    echo "$config" | jq -r 'to_entries[] | "    echo \"  \(.key)  # для \(.value.display_name)\""' >> "$templates_dir/hooks/pre-commit"

    # Добавляем проверку соответствия email и имени
    cat >> "$templates_dir/hooks/pre-commit" << 'EOL'
    exit 1
fi

# Проверяем соответствие email и имени
case "$CURRENT_NAME" in
EOL

    # Добавляем проверки для каждого пользователя
    echo "$config" | jq -r 'to_entries[] | "    \"\(.value.git_username)\")\n        if [ \"$CURRENT_EMAIL\" != \"\(.value.email)\" ]; then\n            echo \"ВНИМАНИЕ! Несоответствие email для пользователя \(.value.display_name)\"\n            echo \"Ожидается: \(.value.email)\"\n            echo \"Получено: $CURRENT_EMAIL\"\n            exit 1\n        fi\n        ;;"' >> "$templates_dir/hooks/pre-commit"

    # Завершаем pre-commit хук
    cat >> "$templates_dir/hooks/pre-commit" << 'EOL'
    *)
        echo "ВНИМАНИЕ! Неразрешенное имя пользователя: $CURRENT_NAME"
        echo "Выполните одну из доступных команд:"
EOL

    echo "$config" | jq -r 'to_entries[] | "        echo \"  \(.key)  # для \(.value.display_name)\""' >> "$templates_dir/hooks/pre-commit"

    echo "        exit 1" >> "$templates_dir/hooks/pre-commit"
    echo "esac" >> "$templates_dir/hooks/pre-commit"

    # Делаем pre-commit хук исполняемым
    chmod +x "$templates_dir/hooks/pre-commit"
    chown "$REAL_USER" "$templates_dir/hooks/pre-commit"

    # Настраиваем Git для использования шаблонов
    sudo -u "$REAL_USER" git config --global init.templatedir "$templates_dir"

    echo -e "${GREEN}Хуки успешно обновлены${NC}"
}

# Проверяем наличие необходимых зависимостей
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Ошибка: jq не установлен${NC}"
    echo "Установите jq с помощью вашего пакетного менеджера"
    echo "Например: sudo apt-get install jq"
    exit 1
fi

# Добавляем алиасы в .bashrc если их еще нет
if ! grep -q "# Git user switch aliases" "$REAL_HOME/.bashrc"; then
    echo -e "\n${BLUE}Добавление алиасов в .bashrc...${NC}"
    cat >> "$REAL_HOME/.bashrc" << 'EOL'

# Git user switch aliases
alias git-check='echo "Current Git user:"; git config user.name; git config user.email'

# Добавляем директорию с командами в PATH
export PATH="$HOME/.config/git-users/commands:$PATH"
EOL
    chown "$REAL_USER" "$REAL_HOME/.bashrc"
fi

# Запускаем интерактивное меню
show_menu
