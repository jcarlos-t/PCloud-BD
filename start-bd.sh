#!/bin/bash
# Script para iniciar los contenedores manualmente

# Lista de contenedores
containers=("adminer_c" "postgre_c" "mysql_c" "mongo_c")

echo "Iniciando contenedores..."
for c in "${containers[@]}"; do
  echo "-> Iniciando $c"
  docker start "$c"
done

echo "Todos los contenedores han sido iniciados."
