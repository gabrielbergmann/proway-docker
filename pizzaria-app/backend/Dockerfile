FROM python as build

WORKDIR /py/app

COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

COPY . .

FROM python:3.13-slim

WORKDIR /py/app

COPY --from=build /install /usr/local

COPY --from=build /py/app .

CMD ["python", "app.py"]
