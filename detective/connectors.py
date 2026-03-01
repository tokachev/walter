"""
connectors.py — connectors for BigQuery and Snowflake
"""

from dataclasses import dataclass, field
from typing import Optional
import os
import re


@dataclass
class QueryResult:
    rows: list = field(default_factory=list)
    columns: list = field(default_factory=list)
    row_count: int = 0
    error: Optional[str] = None


# ─── BigQuery ────────────────────────────────────────────────────────────────

class BigQueryConnector:
    def __init__(self, project: str, credentials_path: Optional[str] = None):
        self.project = project
        self.credentials_path = credentials_path
        self._client = None

    def _get_client(self):
        if self._client is None:
            from google.cloud import bigquery
            from google.oauth2 import service_account

            if self.credentials_path:
                credentials = service_account.Credentials.from_service_account_file(
                    self.credentials_path,
                    scopes=["https://www.googleapis.com/auth/cloud-platform"]
                )
                self._client = bigquery.Client(project=self.project, credentials=credentials)
            else:
                # Application Default Credentials
                self._client = bigquery.Client(project=self.project)
        return self._client

    def test_connection(self):
        client = self._get_client()
        list(client.list_datasets(max_results=1))

    def execute(self, sql: str) -> QueryResult:
        try:
            client = self._get_client()
            job = client.query(sql)
            rows_raw = list(job.result())

            if not rows_raw:
                return QueryResult(rows=[], columns=[], row_count=0)

            columns = [field.name for field in rows_raw[0]._fields]
            rows = [dict(row) for row in rows_raw]

            return QueryResult(rows=rows, columns=columns, row_count=len(rows))

        except Exception as e:
            return QueryResult(error=str(e))

    @staticmethod
    def _validate_identifier(name: str) -> bool:
        """Check that a name is a safe SQL identifier (alphanumeric + underscores/hyphens)."""
        return bool(re.match(r'^[a-zA-Z0-9_\-]+$', name))

    def get_schema(self, table: str) -> QueryResult:
        # Parse the table reference
        parts = table.split(".")
        if len(parts) == 2:
            dataset, table_name = parts
            project = self.project
        elif len(parts) == 3:
            project, dataset, table_name = parts
        else:
            return QueryResult(error=f"Invalid table format: {table}")

        if not all(self._validate_identifier(p) for p in [project, dataset, table_name]):
            return QueryResult(error=f"Invalid characters in table reference: {table}")

        sql = f"""
            SELECT
                column_name,
                data_type,
                is_nullable,
                description
            FROM `{project}.{dataset}.INFORMATION_SCHEMA.COLUMNS`
            WHERE table_name = '{table_name}'
            ORDER BY ordinal_position
        """
        return self.execute(sql)

    def list_tables(self, dataset: str, filter_str: str = None) -> QueryResult:
        parts = dataset.split(".")
        if len(parts) == 2:
            project, ds = parts
        else:
            project = self.project
            ds = dataset

        if not all(self._validate_identifier(p) for p in [project, ds]):
            return QueryResult(error=f"Invalid characters in dataset reference: {dataset}")

        filter_clause = ""
        if filter_str:
            safe_filter = filter_str.lower().replace("'", "''")
            filter_clause = f"AND LOWER(table_name) LIKE '%{safe_filter}%'"

        sql = f"""
            SELECT
                table_name,
                table_type,
                creation_time,
                row_count,
                size_bytes
            FROM `{project}.{ds}.INFORMATION_SCHEMA.TABLES`
            WHERE 1=1
            {filter_clause}
            ORDER BY table_name
        """
        return self.execute(sql)


# ─── Snowflake ───────────────────────────────────────────────────────────────

class SnowflakeConnector:
    def __init__(
        self,
        account: str,
        user: str,
        password: Optional[str] = None,
        private_key_path: Optional[str] = None,
        warehouse: str = "COMPUTE_WH",
        database: Optional[str] = None,
        schema: Optional[str] = None,
        role: Optional[str] = None,
    ):
        self.account = account
        self.user = user
        self.password = password
        self.private_key_path = private_key_path
        self.warehouse = warehouse
        self.database = database
        self.schema = schema
        self.role = role
        self._connection = None

    def _get_connection(self):
        if self._connection is None:
            import snowflake.connector
            from cryptography.hazmat.backends import default_backend
            from cryptography.hazmat.primitives import serialization

            conn_params = {
                "account": self.account,
                "user": self.user,
                "warehouse": self.warehouse,
            }

            if self.role:
                conn_params["role"] = self.role
            if self.database:
                conn_params["database"] = self.database
            if self.schema:
                conn_params["schema"] = self.schema

            if self.private_key_path:
                with open(self.private_key_path, "rb") as key_file:
                    private_key = serialization.load_pem_private_key(
                        key_file.read(),
                        password=os.getenv("SF_PRIVATE_KEY_PASSPHRASE", "").encode() or None,
                        backend=default_backend()
                    )
                conn_params["private_key"] = private_key.private_bytes(
                    encoding=serialization.Encoding.DER,
                    format=serialization.PrivateFormat.PKCS8,
                    encryption_algorithm=serialization.NoEncryption()
                )
            elif self.password:
                conn_params["password"] = self.password
            else:
                raise ValueError("Required: SF_PASSWORD or SF_PRIVATE_KEY_PATH")

            self._connection = snowflake.connector.connect(**conn_params)

        return self._connection

    def test_connection(self):
        conn = self._get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.close()

    def execute(self, sql: str) -> QueryResult:
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute(sql)

            columns = [col[0] for col in cursor.description] if cursor.description else []
            rows_raw = cursor.fetchall()
            cursor.close()

            rows = [dict(zip(columns, row)) for row in rows_raw]
            return QueryResult(rows=rows, columns=columns, row_count=len(rows))

        except Exception as e:
            # Try to reconnect if the connection has gone stale
            self._connection = None
            return QueryResult(error=str(e))

    @staticmethod
    def _validate_identifier(name: str) -> bool:
        """Check that a name is a safe SQL identifier (alphanumeric + underscores)."""
        return bool(re.match(r'^[a-zA-Z0-9_]+$', name))

    def get_schema(self, table: str) -> QueryResult:
        parts = table.split(".")
        if len(parts) == 2:
            schema_name, table_name = parts
        elif len(parts) == 3:
            db_name, schema_name, table_name = parts
        else:
            table_name = table
            schema_name = None

        if not self._validate_identifier(table_name):
            return QueryResult(error=f"Invalid table name: {table_name}")

        db_filter = ""
        if len(parts) == 2 and schema_name:
            if not self._validate_identifier(schema_name):
                return QueryResult(error=f"Invalid schema name: {schema_name}")
            db_filter = f"AND TABLE_SCHEMA = '{schema_name.upper()}'"
        elif len(parts) == 3:
            if not all(self._validate_identifier(p) for p in [db_name, schema_name]):
                return QueryResult(error=f"Invalid identifier in: {table}")
            db_filter = f"AND TABLE_CATALOG = '{db_name.upper()}' AND TABLE_SCHEMA = '{schema_name.upper()}'"

        sql = f"""
            SELECT
                COLUMN_NAME,
                DATA_TYPE,
                IS_NULLABLE,
                CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION,
                COLUMN_DEFAULT,
                COMMENT
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE LOWER(TABLE_NAME) = LOWER('{table_name}')
            {db_filter}
            ORDER BY ORDINAL_POSITION
        """
        return self.execute(sql)

    def list_tables(self, dataset: str, filter_str: str = None) -> QueryResult:
        parts = dataset.split(".")
        schema_name = parts[-1]

        if not self._validate_identifier(schema_name):
            return QueryResult(error=f"Invalid schema name: {schema_name}")

        db_clause = ""
        if len(parts) > 1:
            if not self._validate_identifier(parts[0]):
                return QueryResult(error=f"Invalid database name: {parts[0]}")
            db_clause = f"AND TABLE_CATALOG = '{parts[0].upper()}'"

        filter_clause = ""
        if filter_str:
            safe_filter = filter_str.lower().replace("'", "''")
            filter_clause = f"AND LOWER(TABLE_NAME) LIKE '%{safe_filter}%'"

        sql = f"""
            SELECT
                TABLE_NAME,
                TABLE_TYPE,
                ROW_COUNT,
                BYTES,
                CREATED,
                LAST_ALTERED
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '{schema_name.upper()}'
            {db_clause}
            {filter_clause}
            ORDER BY TABLE_NAME
        """
        return self.execute(sql)
