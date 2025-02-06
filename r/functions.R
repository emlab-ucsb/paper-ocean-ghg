
# This function pulls the necessary GFW data and stores it into a destination table
# This requires special permissions, and is also very expensive to run, so will not be done often
run_gfw_query_and_save_table <- function(sql, 
                                         bq_table_name, 
                                         bq_dataset, 
                                         billing_project, 
                                         bq_project,
                                         # By default:  If the table already exists, BigQuery overwrites the table data
                                         # With "WRITE_APPEND": If the table already exists, BigQuery appends the data to the table.
                                         write_disposition = 'WRITE_TRUNCATE',
                                         ...){
  
  # Specify table where query results will be saved
  bq_table <- bigrquery::bq_table(project = bq_project,
                                  table = bq_table_name,
                                  dataset = bq_dataset)
  
  # Run query and save on BQ. We don't pull this locally yet.
  bigrquery::bq_project_query(billing_project,
                              sql,
                              destination_table = bq_table,
                              use_legacy_sql = FALSE,
                              allowLargeResults = TRUE,
                              write_disposition = write_disposition)
  
  # Return table metadata, for targets to know if something changed
  bigrquery::bq_table_meta(bq_table)
}

# This function pulls GFW data locally from a specific table
# This simply gets all data from the table
pull_gfw_data_locally <- function(bq_table_name, bq_dataset, billing_project, ...){
  bigrquery::bq_project_query(billing_project, 
                              glue::glue("SELECT * FROM world-fishing-827.{bq_dataset}.{bq_table_name}")) |>
    bigrquery::bq_table_download(n_max = Inf)
}