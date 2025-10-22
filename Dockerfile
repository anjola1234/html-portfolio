# Use an official Nginx image
FROM nginx:latest

# Copy your static site to Nginx's default HTML directory
COPY . /usr/share/nginx/html

# Expose port 80 for web traffic
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]

