#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG (ajusta si cambia algo)
# =========================
MYSQL_CONT="mysql_c"
PG_CONT="postgre_c"
MONGO_CONT="mongo_c"

# MySQL
MYSQL_USER="root"
MYSQL_PASS="admin"
MYSQL_DB="ms1_db"

# PostgreSQL (ms2 usa DB 'postgres')
PG_USER="postgres"
PG_DB="postgres"

# MongoDB (según tu compose)
MONGO_DB="ms3"
MONGO_USER="admin"
MONGO_PASS="admin"
MONGO_AUTH_DB="admin"

# Archivos esperados en el directorio actual (SIN encabezados en CSV)
REQUIRED_FILES=(
  "usuarios.csv"            # id_usuario,nombre,correo,contraseña,telefono
  "direcciones.csv"         # id_direccion,id_usuario,direccion,ciudad,codigo_postal
  "categorias.csv"          # id_categoria,descripcion_categoria,nombre_categoria
  "productos.csv"           # id_producto,descripcion,nombre,precio,categoria_id
  "pedidos.json"            # arreglo JSON o NDJSON
  "historialpedidos.json"   # arreglo JSON o NDJSON
)

# =========================
# Helpers
# =========================
die() { echo "ERROR: $*" >&2; exit 1; }

need_file() {
  for f in "${REQUIRED_FILES[@]}"; do
    [[ -f "$f" ]] || die "No se encontró '$f' en el directorio actual $(pwd)"
  done
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker no está instalado en el host"
}

check_container() {
  local name="$1"
  docker ps --format '{{.Names}}' | grep -qx "$name" || die "El contenedor '$name' no está corriendo"
}

copy_into() {
  local file="$1" cont="$2"
  echo "• Copiando $file → $cont:/tmp/$file"
  docker cp "$file" "$cont:/tmp/$file"
}

# Detecta si un JSON es arreglo ([ ... ]) o NDJSON
json_is_array() {
  local file="$1"
  local first_char
  first_char="$(head -c 1 "$file" || true)"
  [[ "$first_char" == "[" ]]
}

# Normaliza finales de línea (por si vienen en CRLF) dentro del contenedor
normalize_crlf_in_container() {
  local cont="$1"; shift
  for f in "$@"; do
    docker exec -i "$cont" bash -lc "if [ -f '/tmp/$f' ]; then sed -i 's/\r\$//' '/tmp/$f'; fi"
  done
}

# =========================
# MySQL: crear estructuras, limpiar datos, importar
# =========================
seed_mysql() {
  echo "==> MySQL ($MYSQL_CONT) → BD '$MYSQL_DB'"

  # 1) Crear BD si no existe
  docker exec -i "$MYSQL_CONT" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e \
    "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

  # 2) Crear tablas si no existen (según ms1) — permiten ID explícito
  docker exec -i "$MYSQL_CONT" mysql --default-character-set=utf8mb4 -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS usuarios (
  id_usuario INT AUTO_INCREMENT PRIMARY KEY,
  nombre VARCHAR(100),
  correo VARCHAR(100) UNIQUE,
  `contraseña` VARCHAR(255),
  telefono VARCHAR(15)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS direcciones (
  id_direccion INT AUTO_INCREMENT PRIMARY KEY,
  id_usuario INT,
  direccion VARCHAR(255),
  ciudad VARCHAR(100),
  codigo_postal VARCHAR(10),
  CONSTRAINT fk_dir_user FOREIGN KEY (id_usuario) REFERENCES usuarios(id_usuario) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL

  # 3) Vaciar datos (mantener estructura) y reiniciar autoincrement
  docker exec -i "$MYSQL_CONT" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" <<'SQL'
SET FOREIGN_KEY_CHECKS=0;
TRUNCATE TABLE direcciones;
TRUNCATE TABLE usuarios;
SET FOREIGN_KEY_CHECKS=1;
SQL

  # 4) Habilitar LOCAL INFILE y normalizar saltos de línea
  docker exec -i "$MYSQL_CONT" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SET GLOBAL local_infile=1;"
  normalize_crlf_in_container "$MYSQL_CONT" "usuarios.csv" "direcciones.csv"

  # 5) Cargar CSVs SIN encabezado y con el ORDEN EXACTO de tus archivos
  echo "• Importando usuarios.csv (id_usuario,nombre,correo,contraseña,telefono)"
  docker exec -i "$MYSQL_CONT" mysql --default-character-set=utf8mb4 --local-infile=1 \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" \
    -e "LOAD DATA LOCAL INFILE '/tmp/usuarios.csv'
        INTO TABLE usuarios
        CHARACTER SET utf8mb4
        FIELDS TERMINATED BY ',' ENCLOSED BY '\"' ESCAPED BY '\\\\'
        LINES TERMINATED BY '\n'
        (id_usuario, nombre, correo, \`contraseña\`, telefono);"

  echo "• Importando direcciones.csv (id_direccion,id_usuario,direccion,ciudad,codigo_postal)"
  docker exec -i "$MYSQL_CONT" mysql --default-character-set=utf8mb4 --local-infile=1 \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" \
    -e "LOAD DATA LOCAL INFILE '/tmp/direcciones.csv'
        INTO TABLE direcciones
        CHARACTER SET utf8mb4
        FIELDS TERMINATED BY ',' ENCLOSED BY '\"' ESCAPED BY '\\\\'
        LINES TERMINATED BY '\n'
        (id_direccion, id_usuario, direccion, ciudad, codigo_postal);"

  echo "✓ MySQL listo"
}

# =========================
# PostgreSQL: crear estructuras, limpiar datos, importar
# =========================
seed_postgres() {
  echo "==> PostgreSQL ($PG_CONT) → BD '$PG_DB'"

  # 1) Crear tablas si no existen (nombres por defecto JPA: categoria, producto)
  docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" <<'PSQL'
CREATE TABLE IF NOT EXISTS categoria (
  id_categoria INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  nombre_categoria VARCHAR(255),
  descripcion_categoria VARCHAR(500)
);

CREATE TABLE IF NOT EXISTS producto (
  id_producto INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  nombre VARCHAR(255),
  descripcion TEXT,
  precio NUMERIC(10,2),
  categoria_id INTEGER REFERENCES categoria(id_categoria) ON DELETE SET NULL
);
PSQL

  # 2) Vaciar datos (y reiniciar identidades)
  docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" <<'PSQL'
TRUNCATE TABLE producto, categoria RESTART IDENTITY CASCADE;
PSQL

  # 3) Normalizar saltos de línea
  normalize_crlf_in_container "$PG_CONT" "categorias.csv" "productos.csv"

  # 4) Importar CSVs SIN encabezado con el ORDEN EXACTO de tus archivos
  echo "• Importando categorias.csv (id_categoria, descripcion_categoria, nombre_categoria)"
  docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" \
    -c "\copy categoria(id_categoria, descripcion_categoria, nombre_categoria) FROM '/tmp/categorias.csv' WITH (FORMAT csv)"

  echo "• Importando productos.csv (id_producto, descripcion, nombre, precio, categoria_id)"
  docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" \
    -c "\copy producto(id_producto, descripcion, nombre, precio, categoria_id) FROM '/tmp/productos.csv' WITH (FORMAT csv)"

  # 5) Ajustar las secuencias para que futuras inserciones sin ID no choquen
  docker exec -i "$PG_CONT" psql -U "$PG_USER" -d "$PG_DB" <<'PSQL'
SELECT setval(pg_get_serial_sequence('categoria','id_categoria'),
              COALESCE((SELECT MAX(id_categoria) FROM categoria), 0), true);
SELECT setval(pg_get_serial_sequence('producto','id_producto'),
              COALESCE((SELECT MAX(id_producto) FROM producto), 0), true);
PSQL

  echo "✓ PostgreSQL listo"
}

# =========================
# MongoDB: limpiar colecciones, importar (arreglo o NDJSON)
# =========================
seed_mongo() {
  echo "==> MongoDB ($MONGO_CONT) → BD '$MONGO_DB'"

  # 1) Drop colecciones (si existen)
  docker exec -i "$MONGO_CONT" mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" --eval \
    "db.getSiblingDB('$MONGO_DB').pedidos.drop(); db.getSiblingDB('$MONGO_DB').historialpedidos.drop();" >/dev/null || true

  # 2) Importar pedidos.json
  if json_is_array "pedidos.json"; then
    echo "• Importando pedidos.json (jsonArray)"
    docker exec -i "$MONGO_CONT" mongoimport \
      --host localhost -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" \
      --db "$MONGO_DB" --collection pedidos --file /tmp/pedidos.json --jsonArray
  else
    echo "• Importando pedidos.json (NDJSON)"
    docker exec -i "$MONGO_CONT" mongoimport \
      --host localhost -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" \
      --db "$MONGO_DB" --collection pedidos --file /tmp/pedidos.json
  fi

  # 3) Importar historialpedidos.json
  if json_is_array "historialpedidos.json"; then
    echo "• Importando historialpedidos.json (jsonArray)"
    docker exec -i "$MONGO_CONT" mongoimport \
      --host localhost -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" \
      --db "$MONGO_DB" --collection historialpedidos --file /tmp/historialpedidos.json --jsonArray
  else
    echo "• Importando historialpedidos.json (NDJSON)"
    docker exec -i "$MONGO_CONT" mongoimport \
      --host localhost -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" \
      --db "$MONGO_DB" --collection historialpedidos --file /tmp/historialpedidos.json
  fi

  # 4) Índices útiles
  docker exec -i "$MONGO_CONT" mongosh -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" --eval \
    "db = db.getSiblingDB('$MONGO_DB');
     db.pedidos.createIndex({ id_usuario: 1, fecha_pedido: -1 });
     db.historialpedidos.createIndex({ id_pedido: 1, fecha_evento: -1 });" >/dev/null || true

  echo "✓ MongoDB listo"
}

# =========================
# MAIN
# =========================
echo "==> Verificaciones"
need_docker
need_file
check_container "$MYSQL_CONT"
check_container "$PG_CONT"
check_container "$MONGO_CONT"

echo "==> Copiando archivos a contenedores (/tmp)"
copy_into "usuarios.csv" "$MYSQL_CONT"
copy_into "direcciones.csv" "$MYSQL_CONT"

copy_into "categorias.csv" "$PG_CONT"
copy_into "productos.csv" "$PG_CONT"

copy_into "pedidos.json" "$MONGO_CONT"
copy_into "historialpedidos.json" "$MONGO_CONT"

seed_mysql
seed_postgres
seed_mongo

echo "🎉 Listo. Estructuras creadas (si faltaban), datos vaciados y nueva data importada en MySQL(ms1_db), PostgreSQL(postgres) y MongoDB(ms3)."
